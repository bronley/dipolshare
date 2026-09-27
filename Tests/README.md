# Regression tests

Run these on a modern Mac with Xcode command-line tools and Python 3. Tests compile the app's production modules with AddressSanitizer; parser/client and receiver-state tests also use UndefinedBehaviorSanitizer. Temporary certificates, executables, and received files are removed when the runners finish.

```sh
sh Tests/Shared/run_tests.sh
sh Tests/Receiving/run_tests.sh
python3 Tests/Sending/run_tests.py
sh Tests/Screens/run_tests.sh
python3 Tests/Networking/test_client_parser.py
sh Tests/Networking/run_transport_tests.sh /path/to/native/openssl-3.5.8
sh Tests/Networking/run_client_tests.sh /path/to/native/openssl-3.5.8
```

The native OpenSSL directory must contain matching headers and `libssl.a`/`libcrypto.a` for the host Mac. The ARMv6/ARMv7 libraries in `Vendor` cannot run on the host. Build the pinned source for the Mac using its native `darwin64` target and the host configuration recorded in `Vendor/OpenSSL/OpenSSL-manifest.json`. `Scripts/build-openssl-ios4.sh` builds the iPhone libraries.

The receiving tests cover approval and refusal, peer/session/token binding, malformed metadata, insufficient space, cancellation, incomplete uploads, staging cleanup, restart persistence, and multi-file batches. Network tests cover real TLS connections, certificate pinning before request bytes are sent, client certificate requirements, streaming bodies, fragmented responses, chunk framing, limits, and disconnects.

Sending tests compile the production transfer class with host substitutes for the iPhone photo library and network/identity services. They exercise clipboard payloads, batch acceptance, ordered uploads, temporary-file cleanup, export failures, cancellation, and redirect refusal. The separate network suites exercise the real HTTPS implementation.

Screen layout tests compile the production radar placement code. They check the requested size range, spacing between blobs and the radar, stable positions during discovery updates, and a usable overflow path on crowded screens.

These checks complement the Xcode 4.2.1/iPhoneOS 5.0 SDK build, which targets iOS 4.2. They do not emulate UIKit or a physical iOS sandbox; test the installed app on a phone before release.
