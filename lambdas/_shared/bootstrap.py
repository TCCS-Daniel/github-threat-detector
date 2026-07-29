import os

import boto3


def load_github_token() -> None:
    if os.environ.get("GITHUB_TOKEN"):
        return
    arn = os.environ.get("GITHUB_TOKEN_SECRET_ARN")
    if not arn:
        return
    client = boto3.client("secretsmanager")
    resp = client.get_secret_value(SecretId=arn)
    os.environ["GITHUB_TOKEN"] = resp["SecretString"]


def split_csv(value: str | None) -> list[str]:
    if not value:
        return []
    return [part.strip() for part in value.split(",") if part.strip()]
