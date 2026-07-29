FROM public.ecr.aws/lambda/python:3.12

COPY lambdas/_shared/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt -t ${LAMBDA_TASK_ROOT}

COPY lambdas/_shared/bootstrap.py ${LAMBDA_TASK_ROOT}/
COPY lambdas/enrich/handler.py ${LAMBDA_TASK_ROOT}/
COPY collectors ${LAMBDA_TASK_ROOT}/collectors
COPY analyzers ${LAMBDA_TASK_ROOT}/analyzers
COPY db ${LAMBDA_TASK_ROOT}/db
COPY config.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.lambda_handler"]
