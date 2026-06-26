# TimescaleDB image for the from_hypertable test track. Pinned to the Supabase fleet version
# (TimescaleDB 2.16.1 on PostgreSQL 15) -- the population from_hypertable targets. The base image is
# Alpine and preloads timescaledb; we only layer in pgTAP (it does not ship it), built from source since
# Alpine has no pgtap package. No pg_prove: the ./test.sh timescale runner drives each test file with
# psql and checks the TAP output, so the image stays lean.
ARG TS_VERSION=2.16.1
FROM timescale/timescaledb:${TS_VERSION}-pg15

ARG PGTAP_REF=v1.3.4
RUN apk add --no-cache --virtual .pgtap-build build-base perl make git \
    && git clone --depth 1 --branch ${PGTAP_REF} https://github.com/theory/pgtap.git \
    && cd pgtap && make && make install && cd .. && rm -rf pgtap \
    && apk del .pgtap-build
