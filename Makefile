PACKAGE=rabbitmq-management
APPNAME=rabbit_management
DEPS=mochiweb rabbitmq-server rabbitmq-erlang-client rabbitmq-management-agent
INTERNAL_DEPS=webmachine
RUNTIME_DEPS=webmachine

TEST_APPS=crypto inets mochiweb webmachine rabbit_management_agent rabbit_management amqp_client
START_RABBIT_IN_TESTS=true
TEST_COMMANDS=rabbit_mgmt_test_all:all_tests()

EXTRA_PACKAGE_DIRS=priv

WEB_DIR=priv/www
JAVASCRIPT_DIR=$(WEB_DIR)/js
TEMPLATES_DIR=$(JAVASCRIPT_DIR)/tmpl
EXTRA_TARGETS=$(wildcard $(TEMPLATES_DIR)/*.ejs) \
    $(wildcard $(JAVASCRIPT_DIR)/*.js) \
    $(wildcard $(WEB_DIR)/*.html) \
    $(wildcard $(WEB_DIR)/css/*.css) \
    $(wildcard $(WEB_DIR)/img/*.png) \
    priv/www-cli/rabbitmqadmin \

include ../include.mk

priv/www/cli/rabbitmqadmin:
	cp bin/rabbitmqadmin $@

test: cleantest

cleantest:
	rm -rf tmp
