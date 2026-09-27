JSONKit 1.4 source is pinned at commit 82157634ca0ca5b6a4a67a194dd11f15d9b72835.
Original JSONKit.h SHA-256: 53be670f97841363321047cf1747033c6bfafd489caeffaf7c984026c1aa2a64
Original JSONKit.m SHA-256: e77e8538e6460380ea35ecfef7b1ef4457cf4231131cd0b290026006125627e8

Local changes to JSONKit.m replace direct ISA assignment and inspection with Objective-C
runtime functions. This preserves behavior on the legacy runtime and allows the host
regression tests to run on current macOS, where tagged and signed ISA pointers exist.

The app uses the BSD license option. Preserve LICENSE-JSONKit.txt in source and binary
distributions.
