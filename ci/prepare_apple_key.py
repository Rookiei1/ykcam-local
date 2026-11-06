"""Prepare the App Store Connect Team API key inside the disposable GitHub runner."""
import os
from pathlib import Path


def main():
    required = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY")
    missing = [name for name in required if not os.environ.get(name, "").strip()]
    if missing:
        raise RuntimeError("Configure these GitHub Actions secrets: " + ", ".join(missing))

    value = os.environ["ASC_PRIVATE_KEY"].replace("\\n", "\n").strip() + "\n"
    if "-----BEGIN PRIVATE KEY-----" not in value and "-----BEGIN EC PRIVATE KEY-----" not in value:
        raise RuntimeError("ASC_PRIVATE_KEY must contain the complete .p8 private key.")

    path = Path(os.environ["RUNNER_TEMP"]) / "ykcam-asc" / "AuthKey.p8"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value, encoding="utf-8")
    path.chmod(0o600)

    with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as environment:
        environment.write(f"ASC_KEY_PATH={path}\n")

    print("Prepared the Apple API key in the temporary runner directory.")


if __name__ == "__main__":
    main()
