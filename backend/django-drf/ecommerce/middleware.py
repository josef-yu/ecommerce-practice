"""All project middlewares are to be put here."""

from collections.abc import Callable
from http import HTTPStatus

from django.http import HttpRequest, HttpResponse


class HealthCheckMiddleware:
    """Middleware for health check.

    Make sure that this is to be put first into the middleware stack.
    """

    def __init__(self, get_response: Callable[[HttpRequest], HttpResponse]) -> None:  # noqa: D107
        self.get_response = get_response

    def __call__(self, request: HttpRequest) -> HttpResponse:  # noqa: D102
        if request.path == "/health":
            return HttpResponse(status=HTTPStatus.OK)

        return self.get_response(request)
