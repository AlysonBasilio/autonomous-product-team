FROM ruby:3.2-slim

ENV BUNDLE_DEPLOYMENT=1 \
    BUNDLE_WITHOUT=test \
    ORCHESTRATOR_BIND=0.0.0.0 \
    ORCHESTRATOR_DATA_DIR=/data

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

EXPOSE 4242
CMD ["bundle", "exec", "ruby", "orchestrator/run.rb"]
