"""All app specific configurations like signals and settings can be put here."""

from django.apps import AppConfig


class UserConfig(AppConfig):
    """App config for user sub-app."""

    name = "user"
