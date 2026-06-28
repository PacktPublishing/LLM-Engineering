import concurrent.futures

import opik
from loguru import logger
from qdrant_client.models import FieldCondition, Filter, MatchValue

from llm_engineering.application import utils
from llm_engineering.application.preprocessing.dispatchers import EmbeddingDispatcher
from llm_engineering.domain.embedded_chunks import (
    EmbeddedArticleChunk,
    EmbeddedChunk,
    EmbeddedPostChunk,
    EmbeddedRepositoryChunk,
)
from llm_engineering.domain.queries import EmbeddedQuery, Query

from .hybrid_search import BM25Retriever, reciprocal_rank_fusion
from .query_expanison import QueryExpansion
from .reranking import Reranker
from .self_query import SelfQuery

# Number of documents scrolled per collection to build the BM25 keyword index.
_BM25_CORPUS_SIZE = 200

# Dense candidates fetched per category per expanded query (fed into RRF).
_DENSE_CANDIDATES_MULTIPLIER = 3


class ContextRetriever:
    def __init__(self, mock: bool = False) -> None:
        self._query_expander = QueryExpansion(mock=mock)
        self._metadata_extractor = SelfQuery(mock=mock)
        self._reranker = Reranker(mock=mock)
        self._bm25 = BM25Retriever()

    @opik.track(name="ContextRetriever.search")
    def search(
        self,
        query: str,
        k: int = 3,
        expand_to_n_queries: int = 3,
    ) -> list:
        query_model = Query.from_str(query)

        query_model = self._metadata_extractor.generate(query_model)
        logger.info(
            f"Successfully extracted the author_full_name = {query_model.author_full_name} from the query.",
        )

        n_generated_queries = self._query_expander.generate(query_model, expand_to_n=expand_to_n_queries)
        logger.info(
            f"Successfully generated {len(n_generated_queries)} search queries.",
        )

        author_filter = self._build_author_filter(query_model)
        bm25_corpora = self._fetch_bm25_corpora(query_filter=author_filter)

        with concurrent.futures.ThreadPoolExecutor() as executor:
            search_tasks = [
                executor.submit(self._search_hybrid, _query_model, k, bm25_corpora)
                for _query_model in n_generated_queries
            ]

            n_k_documents = [task.result() for task in concurrent.futures.as_completed(search_tasks)]
            n_k_documents = utils.misc.flatten(n_k_documents)
            n_k_documents = list(set(n_k_documents))

        logger.info(f"{len(n_k_documents)} documents retrieved successfully")

        if len(n_k_documents) > 0:
            k_documents = self.rerank(query, chunks=n_k_documents, keep_top_k=k)
        else:
            k_documents = []

        return k_documents

    def _build_author_filter(self, query: Query) -> Filter | None:
        if not query.author_id:
            return None
        return Filter(
            must=[
                FieldCondition(
                    key="author_id",
                    match=MatchValue(value=str(query.author_id)),
                )
            ]
        )

    def _fetch_bm25_corpora(self, query_filter: Filter | None) -> dict[type[EmbeddedChunk], list[EmbeddedChunk]]:
        """Scroll each collection once to build per-category BM25 corpora."""
        categories: list[type[EmbeddedChunk]] = [
            EmbeddedPostChunk,
            EmbeddedArticleChunk,
            EmbeddedRepositoryChunk,
        ]
        corpora = {}
        for category in categories:
            corpora[category] = category.scroll_for_bm25(
                limit=_BM25_CORPUS_SIZE,
                query_filter=query_filter,
            )
        logger.info(
            f"BM25 corpora fetched: "
            + ", ".join(f"{cls.__name__}={len(docs)}" for cls, docs in corpora.items())
        )
        return corpora

    def _search_hybrid(
        self,
        query: Query,
        k: int,
        bm25_corpora: dict[type[EmbeddedChunk], list[EmbeddedChunk]],
    ) -> list[EmbeddedChunk]:
        assert k >= 3, "k should be >= 3"

        embedded_query: EmbeddedQuery = EmbeddingDispatcher.dispatch(query)
        author_filter = self._build_author_filter(query)

        candidates_per_category = max(1, k // 3) * _DENSE_CANDIDATES_MULTIPLIER
        retrieved: list[EmbeddedChunk] = []

        categories: list[type[EmbeddedChunk]] = [
            EmbeddedPostChunk,
            EmbeddedArticleChunk,
            EmbeddedRepositoryChunk,
        ]
        for category in categories:
            dense_results = category.search(
                query_vector=embedded_query.embedding,
                limit=candidates_per_category,
                query_filter=author_filter,
            )

            bm25_corpus = bm25_corpora.get(category, [])
            bm25_results = self._bm25.retrieve(
                query=query.content,
                documents=bm25_corpus,
                top_k=candidates_per_category,
            )

            fused = reciprocal_rank_fusion(dense_results, bm25_results)
            retrieved.extend(fused[: candidates_per_category])

        return retrieved

    def rerank(self, query: str | Query, chunks: list[EmbeddedChunk], keep_top_k: int) -> list[EmbeddedChunk]:
        if isinstance(query, str):
            query = Query.from_str(query)

        reranked_documents = self._reranker.generate(query=query, chunks=chunks, keep_top_k=keep_top_k)

        logger.info(f"{len(reranked_documents)} documents reranked successfully.")

        return reranked_documents
