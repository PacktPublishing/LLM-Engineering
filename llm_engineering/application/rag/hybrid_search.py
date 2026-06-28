import re

from rank_bm25 import BM25Okapi

from llm_engineering.domain.embedded_chunks import EmbeddedChunk


def _tokenize(text: str) -> list[str]:
    return re.findall(r"\w+", text.lower())


class BM25Retriever:
    """Keyword-based retrieval using BM25Okapi over a pre-fetched document corpus."""

    def retrieve(self, query: str, documents: list[EmbeddedChunk], top_k: int) -> list[EmbeddedChunk]:
        if not documents:
            return []

        tokenized_corpus = [_tokenize(doc.content) for doc in documents]
        bm25 = BM25Okapi(tokenized_corpus)

        scores = bm25.get_scores(_tokenize(query))
        scored = sorted(zip(scores, documents, strict=False), key=lambda x: x[0], reverse=True)
        return [doc for _, doc in scored[:top_k]]


def reciprocal_rank_fusion(*ranked_lists: list[EmbeddedChunk], k: int = 60) -> list[EmbeddedChunk]:
    """
    Fuse multiple ranked lists into one using Reciprocal Rank Fusion.

    RRF score for document d: sum over each list of 1 / (k + rank(d))
    where rank is 1-based. Higher score = more relevant.
    """
    scores: dict = {}
    doc_map: dict = {}

    for ranked_list in ranked_lists:
        for rank, doc in enumerate(ranked_list):
            doc_id = doc.id
            if doc_id not in scores:
                scores[doc_id] = 0.0
                doc_map[doc_id] = doc
            scores[doc_id] += 1.0 / (k + rank + 1)

    sorted_ids = sorted(scores.keys(), key=lambda id_: scores[id_], reverse=True)
    return [doc_map[id_] for id_ in sorted_ids]
