#!/bin/bash
go build 
docker build -t redis:entrypoint-test  .
docker run -it --name test --rm \
  -v $(pwd)/redis.conf:/etc/redis/external.conf.d/redis-external.conf \
  -e REDIS_PASSWORD=123 \
  -e MEASURE_PASSWORD=exporter@123 \
  redis:entrypoint-test
  #-e SETUP_MODE=sentinel \
  #-e SETUP_MODE=cluster \
#docker logs test
#docker exec -it test sh
#docker stop test 


