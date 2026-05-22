import azure.functions as func
import structlog

from logging_config import configure_logging

configure_logging()

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

_log = structlog.get_logger(__name__)


@app.route(route="hello")
def hello(req: func.HttpRequest) -> func.HttpResponse:
    _log.info("hello_request", method=req.method)
    return func.HttpResponse("Hello CloudODS")
