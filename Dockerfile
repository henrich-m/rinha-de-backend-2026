FROM ruby:4

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl libblas-dev liblapack-dev libjemalloc2 && \
    rm -rf /var/lib/apt/lists/*

ENV LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
ENV RUBY_YJIT_ENABLE=1

COPY api/Gemfile api/Gemfile.lock ./
RUN bundle install -j4

COPY search/index.faiss search/labels.bin ./
COPY api/ .

CMD ["bundle", "exec", "falcon", "host", "falcon.rb"]
