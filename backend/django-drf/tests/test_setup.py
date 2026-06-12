from django.core.mail import send_mail
from django.test import TestCase
from django.test.utils import override_settings


class HealthCheckTest(TestCase):
    def test_endpoint(self):
        response = self.client.get("/health")

        self.assertEqual(response.status_code, 200)


class EmailIntegrationTest(TestCase):
    # Enforce the SMTP backend strictly for this test case
    @override_settings(EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend")
    def test_mailpit_delivery(self):
        sent = send_mail("Integration Test", "Body", "sender@test.com", ["receiver@test.com"])
        self.assertEqual(sent, 1)
