from typing import Annotated, Any

from zenml import ArtifactConfig, get_step_context, step
from zenml.client import Client

from llm_engineering.domain.dataset import InstructTrainTestSplit
from llm_engineering.domain.prompt import GenerateDatasetSamplesPrompt
from llm_engineering.domain.types import DataCategory

artifact = Client().get_artifact_version("307e1964-70bb-4b6a-abcd-defff782ca3b")
loaded_artifact = artifact.load()


@step
def generate_instruct_dataset(
    prompts: Annotated[dict[DataCategory, list[GenerateDatasetSamplesPrompt]], "prompts"],
) -> Annotated[
    InstructTrainTestSplit,
    ArtifactConfig(
        name="instruct_datasets",
        tags=["dataset", "instruct", "cleaned"],
    ),
]:
    datasets = loaded_artifact  # generate the datasets
    step_context = get_step_context()
    step_context.add_output_metadata(output_name="instruct_datasets", metadata=_get_metadata_instruct_dataset(datasets))
    return datasets


def _get_metadata_instruct_dataset(datasets: InstructTrainTestSplit) -> dict[str, Any]:
    instruct_dataset_categories = list(datasets.train.keys())
    train_num_samples = {
        category: instruct_dataset.num_samples for category, instruct_dataset in datasets.train.items()
    }
    test_num_samples = {category: instruct_dataset.num_samples for category, instruct_dataset in datasets.test.items()}

    return {
        "data_categories": instruct_dataset_categories,
        "test_split_size": test_num_samples,
        "train_num_samples_per_category": train_num_samples,
        "test_num_samples_per_category": test_num_samples,
    }
