# Terminal Setup

To get everything looking nice in Neovim, I applied a couple settings to my terminal app. On Windows, I'm using the default terminal app. On Mac, I like to use ITerm2 which you can find on the AppStore.

## ITerm2 Setup

## Terminal Setup (Windows)

It's worth noting that I had to manually go into the `System > Display` settings on my Windows computer to set the optimal resolution and refresh rate. Also taking a moment to configure the brightness you desire is a good step to take before continuing any further.

**Terminal > Settings > Appearance**

* Application Theme: `Dark`
* Use acrylic material in the tab row: `On`
* Pane animations: `On`


**Terminal > Settings > Color schemes**

To get the best theme results, I chose to opt for default colors here so we have less to overwrite later.

1. Click on `+ Add New`
2. Don't modify the colors (or do)
3. Set color scheme as default
4. Rename color scheme (optional)
5. Save

**Terminal > Settings > Rendering**

* Graphics API: `Direct3D 11`
* Disable partial Swap Chain invalidation: `Off`
* Use software rendering (WARP): `Off`

**Terminal > Settings > Shell**

I like to use WSL (Windows Subsystem for Linux) because Linux shells are just better supported for development. (access to bash, package managers, POSIX tools like grep and ssh)

Go into **Appearance**.

Text

* Color scheme: Choose the color scheme you just added.
* Font face: 0xProto Nerd Font ([Download 0xProto](https://github.com/ryanoasis/nerd-fonts/releases/download/v3.4.0/0xProto.zip))
* Font size: 16
* Line height: 1.35
* Font weight: Medium
* Builtin Glyphs: On
* Full-color Emoji: On
* Retro terminal effects: Off
* Automatically adjust lightness of indistinguishable text: Always

Cursor

* Cursor shape: Underscore (_)

Text Formatting

* Intense text style: Bold font with bright colors

Transparency

* Background opacity: 86%
* Enable acrylic material: On

Window

* Padding: 8
* Scrollbar visibility: Hidden
