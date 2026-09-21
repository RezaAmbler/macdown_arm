# MacDown (Apple Silicon fork)

MacDown is an open source Markdown editor for macOS, released under the MIT
License. The author stole the idea from [Chen Luo](https://twitter.com/chenluois)’s
[Mou](http://mouapp.com) so that people can make crappy clones.

This is a fork of [MacDownApp/macdown](https://github.com/MacDownApp/macdown),
which is no longer maintained — its Homebrew cask was disabled in 2026 for
failing the macOS Gatekeeper check. This fork builds natively for Apple
Silicon, runs on current macOS, and renders the preview with `WKWebView`
instead of the long-deprecated `WebView`.

Requires **macOS 14 or later** on an **Apple Silicon** Mac.

## Install

Download `MacDown-arm64.zip` from the
[latest release](https://github.com/RezaAmbler/macdown_arm/releases/latest),
unzip it, and drag `MacDown.app` to your Applications folder.

### First launch

These builds are ad-hoc signed rather than notarized by Apple, so macOS will
refuse to open the app the first time and say it cannot verify the developer.
This is expected. To allow it:

1. Double-click MacDown once and dismiss the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll to the **Security** section, find the message about MacDown being
   blocked, and click **Open Anyway**.
4. Confirm with Touch ID or your password.

> Older instructions tell you to Control-click the app and choose *Open*.
> Apple removed that route in macOS 15, so on a current system the Privacy &
> Security panel is the way.

If you would rather do it from a terminal, this has the same effect:

    xattr -dr com.apple.quarantine /Applications/MacDown.app

You only have to do this once. Updates delivered through the app's own
updater are not quarantined, so they install without any of the above.

## Screenshot

![screenshot](assets/screenshot.png)

## License

MacDown is released under the terms of MIT License. You may find the content of the license [here](http://opensource.org/licenses/MIT), or inside the `LICENSE` directory.

You may find full text of licenses about third-party components in the `LICENSE` directory, or the **About MacDown** panel in the application.

The following editor themes and CSS files are extracted from [Mou](http://mouapp.com), courtesy of Chen Luo:

* Mou Fresh Air
* Mou Fresh Air+
* Mou Night
* Mou Night+
* Mou Paper
* Mou Paper+
* Tomorrow
* Tomorrow Blue
* Tomorrow+
* Writer
* Writer+
* Clearness
* Clearness Dark
* GitHub
* GitHub2

## Development

### Requirements

If you wish to build MacDown yourself, you will need the following components/tools:

* Xcode 27 or later (tested on Xcode 27.0 / macOS 27)
* A Mac running macOS 14.0 or later (this fork is Apple Silicon only)
* Git
* CocoaPods 1.17 or later

Install CocoaPods with Homebrew:

    brew install cocoapods

> Note: do **not** use the system Ruby with Bundler to run CocoaPods. macOS 27's
> bundled Ruby 2.6 can no longer compile the native extensions the older
> CocoaPods releases depend on. The Homebrew formula ships its own Ruby and is
> the supported path.

> Note: the Command Line Tools (CLT) should be unnecessary, and an out-of-date
> CLT can actively break the build — its SDK may shadow Xcode's. If a
> dependency's `./configure` step fails to link, point the build at Xcode's SDK
> explicitly:
>
>     export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
>     export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

### Environment Setup

After cloning the repository, run the following commands inside the repository root (directory containing this `README.md` file):

    git submodule update --init
    pod install
    make -C Dependency/peg-markdown-highlight

and open `MacDown.xcworkspace` in Xcode. The first command initialises the dependency submodule(s) used in MacDown; the second one installs dependencies managed by CocoaPods.

Refer to the official guides of Git and CocoaPods if you need more instructions. If you run into build issues later on, try running the following commands to update dependencies:

    git submodule update
    pod install

### Regenerating the GitHub-2020 style

`MacDown/Resources/Styles/GitHub-2020.css` is generated from `index.sass` but is
committed to the repository, so a normal build needs no Node toolchain. To
regenerate it after changing the source:

    cd Tools/GitHub-style-generator
    npm install
    make

### Translation

Please help translation on [Transifex](https://www.transifex.com/macdown/macdown/).

![Transifex translation percentage](https://www.transifex.com/projects/p/macdown/resource/macdownxliff/chart/image_png/)

## Discussion

Problems with *this fork* belong in
[its issue tracker](https://github.com/RezaAmbler/macdown_arm/issues) — please
**search first** in case it is already reported. The upstream project is no
longer maintained, so filing there is unlikely to reach anyone.

If the problem also happens in upstream MacDown 0.8.x, say so in the report:
it helps to know whether something is a fork regression or has been there all
along.

MacDown depends a lot on other open source projects, such as [Hoedown](https://github.com/hoedown/hoedown) for Markdown-to-HTML rendering, [Prism](http://prismjs.com) for syntax highlighting (in code blocks), and [PEG Markdown Highlight](https://github.com/ali-rantakari/peg-markdown-highlight) for editor highlighting. If you find problems when using those particular features, you can also consider reporting them directly to upstream projects as well as to MacDown’s issue tracker. I will do what I can if you report it here, but sometimes it can be more beneficial to interact with them directly.

## Tipping

If you find MacDown suitable for your needs, please consider [giving me a tip through PayPal](http://macdown.uranusjr.com/faq/#donation). Or, if you prefer to buy me a drink *personally* instead, just [send me a tweet](https://twitter.com/uranusjr) when you visit [Taipei, Taiwan](http://en.wikipedia.org/wiki/Taipei), where I live. I look forward to meeting you!

