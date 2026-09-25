# PAR-76's app image: every service and the executor (ROLE picks which). Built by build-image.sh
# on onboarding, and by the CI build for a pull request (ops/ci/cascade.yml, build.images).
FROM python:3.12.7-slim
RUN pip install --no-cache-dir "psycopg[binary]==3.2.3" "psycopg-pool==3.2.4"
COPY cascade_app.py /app/cascade_app.py
USER 65534
CMD ["python", "-u", "/app/cascade_app.py"]
