# Current Operator version
OPERATOR ?= 1.2.14
VERSION ?= v6.2.5
EMPTY = $(shell echo ${VERSION} | awk -F "[.]" '{print $$1"."$$2}')


build: docker-build huawei-build

docker-build:
	docker buildx build --platform linux/arm64,linux/amd64 -t radondb/redis:$(EMPTY)-${OPERATOR} . --push
	docker buildx build --platform linux/arm64,linux/amd64 -t radondb/redis:$(EMPTY) . --push
	docker buildx build --platform linux/arm64,linux/amd64 -t radondb/redis:${VERSION} . --push

huawei-build:
	docker buildx build --platform linux/arm64 -t dockerhub.kubekey.local/huawei/redis-arm:$(EMPTY)-${OPERATOR} . --load
	docker push dockerhub.kubekey.local/huawei/redis-arm:$(EMPTY)-${OPERATOR} 
	docker buildx build --platform linux/arm64 -t dockerhub.kubekey.local/huawei/redis-arm:$(EMPTY) . --load
	docker push dockerhub.kubekey.local/huawei/redis-arm:$(EMPTY)  
	docker buildx build --platform linux/arm64 -t dockerhub.kubekey.local/huawei/redis-arm:$(VERSION) . --load
	docker push dockerhub.kubekey.local/huawei/redis-arm:$(VERSION)  
	

test-build:
	docker build -t nosqlpass/redis:$(EMPTY)-${OPERATOR} .
	docker push nosqlpass/redis:$(EMPTY)-${OPERATOR}


