# Security Policy

## Reporting a vulnerability

Please report security issues privately via GitHub Security Advisories on
https://github.com/supplychain-labs/github-threat-detector
(or email the maintainers). Do not open a public issue for secrets or active exploits.

## Secrets

Never commit `.env`, `deploy/aws.env`, or `webhook/.deploy.secrets.json`.
Use `.env.example` and `deploy/aws.env.example` as templates only.
