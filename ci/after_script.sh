#!/bin/bash

if [[ "$STAGE" == "coverage" && "$TRAVIS_BRANCH" == "master" ]]; then
  $HOME/.local/bin/aws s3 sync coverage_json s3://aqueduct-coverage-storage/coverage
fi

if [ -a coverage/lcov.info ]; then
  curl -s https://codecov.io/bash > .codecov
  chmod +x .codecov
  ./.codecov -f coverage/lcov.info -X xcode
fi
