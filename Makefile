USER_ID=$(shell id -u)

DOCKER_COMPOSE = @USER_ID=$(USER_ID) docker compose
DOCKER_COMPOSE_RUN = ${DOCKER_COMPOSE} run --rm app
DOCKER_COMPOSE_EXEC = ${DOCKER_COMPOSE} exec

c ?= app

%:
	@:

help: ## This help
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init: ## Initialize environment
	$(MAKE) down
	$(MAKE) build
	$(MAKE) up
	$(MAKE) router-restart

router-restart:
	docker restart router-nginx
	docker restart router-letsencrypt

install: ## Install dependencies without running the whole application
	${DOCKER_COMPOSE_RUN} composer install

build: ## Build services. Supports service name argument
	${DOCKER_COMPOSE} build $(filter-out $@,$(MAKECMDGOALS)) --no-cache

up: ## Create and start services. Supports service name argument
	${DOCKER_COMPOSE} up -d $(filter-out $@,$(MAKECMDGOALS))

stop: ## Stop services. Supports service name argument
	${DOCKER_COMPOSE} stop $(filter-out $@,$(MAKECMDGOALS))

start: ## Start services. Supports service name argument
	${DOCKER_COMPOSE} start $(filter-out $@,$(MAKECMDGOALS))

down: ## Stop and remove containers and volumes. Supports service name argument
	${DOCKER_COMPOSE} down -v $(filter-out $@,$(MAKECMDGOALS))

restart: ## Restart all services or specific service. Supports service name argument
	${DOCKER_COMPOSE} stop $(filter-out $@,$(MAKECMDGOALS))
	${DOCKER_COMPOSE} start $(filter-out $@,$(MAKECMDGOALS))
	$(MAKE) router-restart

bash: ## Login in console. Supports service name argument
	${DOCKER_COMPOSE_EXEC} $(filter-out $@,$(MAKECMDGOALS)) /bin/bash