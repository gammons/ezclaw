FROM ruby:4.0-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
ENV BUNDLE_WITHOUT="test"
RUN bundle install && \
    rm -rf /usr/local/bundle/cache/*.gem

COPY lib/ lib/
COPY grantclaw.rb .

RUN useradd -m -s /bin/bash grantclaw
USER grantclaw

ENTRYPOINT ["ruby", "grantclaw.rb"]
CMD ["--bot", "/config", "--data", "/data"]
