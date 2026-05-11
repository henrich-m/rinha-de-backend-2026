# ── Stage 1: train ──────────────────────────────────────────────
FROM ruby:4 AS trainer

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    cmake g++ libblas-dev liblapack-dev && \
    rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install -j4

COPY src/knn_trainer.rb ./src/
COPY resources/references.json.gz ./resources/

RUN bundle exec ruby src/knn_trainer.rb

# ── Stage 2: runtime ────────────────────────────────────────────
FROM ruby:4

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl libblas-dev liblapack-dev libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

COPY Gemfile Gemfile.lock ./
RUN bundle install -j4

COPY --from=trainer /app/index.faiss /app/labels.bin ./
COPY . .

CMD ["bundle", "exec", "falcon", "host", "falcon.rb"]
