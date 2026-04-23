FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    jq \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
ENV BUNDLE_WITHOUT="test"
RUN bundle install && \
    rm -rf /usr/local/bundle/cache/*.gem

COPY lib/ lib/
COPY ezclaw.rb .

RUN useradd -m -s /bin/bash ezclaw
USER ezclaw

ENTRYPOINT ["ruby", "ezclaw.rb"]
CMD ["--bot", "/config", "--data", "/data"]
