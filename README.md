# 🌐 vless-validator

## Simple script for linux and Android* for testing VLESS lists

Allows you to automatically test a bunch of `vless://` links with real URLs.

> *Use Termux app <https://github.com/termux/termux-app> for Android.

---

### ⬇️ How to download

```shell
curl -o "vless-validator.sh" -L "https://raw.githubusercontent.com/F33RNI/vless-validator/refs/heads/main/vless-validator.sh" && chmod +x vless-validator.sh && ./vless-validator.sh help
```

---

### ❓ Getting started

This script downloads / parses file with multiple `vless://` links / parses single `vless://` link, converts it to the sing-box format, starts local proxy and tests it with real URL. Script will also automatically download sing-box binary if needed.

```text
Usage: ./vless-validator.sh LINK_OR_FILE [NUMBER_OF_LINKS_TO_TEST]

Note:
  Add "r" before NUMBER_OF_LINKS_TO_TEST to select N random lines;
  add "-" before NUMBER_OF_LINKS_TO_TEST to select N lines from the bottom.
  If needed, you can define environment variables in a .env file.

Environment variables:
  TEST_URL - URL to test via VLESS. Current: http://example.com
  DNS_SERVER - Remote UDP DNS server IP. Current: 8.8.8.8
  SING_BOX_PATH - Path to sing-box binary (can be auto-downloaded)
  CONN_TIMEOUT - --connect-timeout for curl. Current: 3
  MAX_TIME - --max-time for curl. Current: 6
  RETRIES - --retry for curl. Current: 1

Examples:
  ./vless-validator.sh vless://UUID@IP:PORT?flow=xtls-rpr...
  ./vless-validator.sh path/to/file_with_links_to_test.txt
  ./vless-validator.sh path/to/file_with_links_to_test.txt 20
  ./vless-validator.sh path/to/file_with_links_to_test.txt -10
  ./vless-validator.sh https://web/path/to/file_to_download_and_test.txt r5
```

> ℹ️ vless-validator saves logs in current directory.
>
> Run `cat "$(ls -A vless-validator*.log | tail -n 1)"` to print latest log file.

---

### 🌲 Dependencies

- <https://github.com/SagerNet/sing-box>
