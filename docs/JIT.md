# Enabling JIT with SideStore and StikDebug

VibeStation5's iOS target carries the entitlement needed to appear as a debugger/JIT target:

- `get-task-allow`

The app also detects debugger activation and performs a `MAP_JIT` writable/executable-memory probe. If activation or the probe is unavailable, VibeStation5 remains usable through its ARM64-native Swift x86-64 interpreter.

The macOS hardened-runtime target separately declares `com.apple.security.cs.allow-jit` and `com.apple.security.cs.allow-unsigned-executable-memory`. Do not force those two macOS code-signing entitlements into a normal iOS development profile: iPadOS rejects the signature because the provisioning profile does not grant them. On iOS, StikDebug enables JIT by attaching a debugger to a `get-task-allow` process.

![VibeStation5 showing get-task-allow and the iPadOS 27 TXM StikDebug status on a physical iPad Pro](screenshots/jit-settings-ipad.png)

## SideStore setup

1. Build and sideload VibeStation5 with development signing or install a SideStore-signed IPA. Distribution signing does not provide `get-task-allow`.
2. In VibeStation5, open **Settings** and leave **Use JIT when externally enabled** turned on.
3. Follow the current [SideStore JIT guide](https://docs.sidestore.io/docs/advanced/jit) to install StikDebug and import the same pairing file used by SideStore.
4. After each device restart, open StikDebug with Wi-Fi and LocalDevVPN connected so it can mount the developer disk image.
5. Launch VibeStation5 normally—not under the Xcode debugger.
6. Enable LocalDevVPN, select VibeStation5 in StikDebug, and activate JIT.
7. Return to VibeStation5 and tap **Refresh JIT Status**. A successful activation reports **JIT memory ready**.

SideStore's built-in **Enable JIT** action is primarily for iOS 16 and older/non-TXM devices. Current iOS and iPadOS versions use StikDebug or another compatible external debugger path.

## iPadOS 26 and 27 limitation

Apple's Trusted Execution Monitor (TXM) changed JIT behavior in iOS/iPadOS 26. The SideStore documentation currently says 26.6 and 27 only work with a short list of explicitly compatible apps. VibeStation5 is not yet on that published list.

The VibeStation5 implementation makes the app correctly signed, discoverable, and able to verify JIT memory. It does not bypass TXM or guarantee that the current StikDebug release can activate VibeStation5 on iPadOS 27. When activation fails, the Settings screen explains the missing step and the interpreter remains available.

## Backend status

JIT activation and an x86-64-to-ARM64 dynamic recompiler are separate layers. This change provides the signing, external activation, executable-memory code-cache foundation, and runtime detection required for JIT. Guest execution continues through the Swift interpreter until the dynamic translator is connected to that code cache.

References:

- [SideStore: Enabling JIT](https://docs.sidestore.io/docs/advanced/jit)
- [StikDebug](https://github.com/StephenDev0/StikDebug)
- [StikJIT](https://github.com/StephenDev0/StikJIT)
