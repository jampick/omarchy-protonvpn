import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Proton VPN bar widget: one icon, one panel.
//
// Built on the same bones as the first-party Network and Tailscale panels --
// a BarIconButton anchoring a KeyboardPanel, a single-cursor navigation model
// shared by mouse and keyboard, and CursorSurface for every highlightable row.
//
// The one idea that is this panel's own: the icon distinguishes "the tunnel is
// up" from "the tunnel is up AND carrying your traffic and DNS". Those are not
// the same thing, and only the second one is protection.
Panel {
  id: root
  moduleName: "jampick.protonvpn"
  ipcTarget: "jampick.protonvpn"
  // The panel owns the single IpcHandler the target permits, so it can expose
  // connect/disconnect routes on top of the base open/close set.
  manageIpc: false

  Service {
    id: vpn
    settings: root.settings
    panelOpen: root.opened
  }

  // --- Theme ------------------------------------------------------------------
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // --- Derived state ----------------------------------------------------------
  // See Service.qml: `state` is taken by QQuickItem.
  readonly property string vpnState: vpn.tunnelState
  readonly property bool leaking: vpn.leaking
  readonly property string icon: Model.stateIcon(vpnState)

  // The bar icon is the whole point of the widget, so it earns its colours:
  // full-strength foreground only when the tunnel is genuinely carrying
  // traffic, urgent when it claims to be up and is not, and dimmed when off.
  readonly property color barIconColor: {
    if (leaking) return bar ? bar.urgent : Color.urgent
    if (vpnState === "protected") return barForeground
    return Qt.darker(barForeground, 1.55)
  }

  readonly property color panelIconColor: {
    if (leaking) return urgent
    if (vpnState === "protected") return foreground
    return dim
  }

  property int phraseIndex: 0
  readonly property var phrases: [
    "Sealing the tunnel",
    "Scrambling routes",
    "Hiding tracks",
    "Guarding DNS",
    "Shuffling exits",
    "Wrapping packets",
    "Bending traffic"
  ]
  readonly property string phrase: phrases[phraseIndex % phrases.length]

  readonly property string heroTitle: vpn.connected && vpn.server !== "" ? vpn.server : "Proton VPN"

  // The hero's second line answers "where am I" once the slow tier lands, and
  // falls back to the flavour phrase in the second or two before it does --
  // rather than flashing an empty line and reflowing the panel.
  readonly property string heroMeta: {
    if (!vpn.installed) return "PROTON VPN CLI NOT INSTALLED"
    if (vpn.guiRunning) return "DESKTOP APP HAS THE CLI"
    if (vpn.needsSignIn) return "NOT SIGNED IN"
    if (vpnState === "connecting") return "CONNECTING…"
    if (vpnState === "off") return "NOT CONNECTED"
    if (leaking) return vpn.leakReason.toUpperCase()
    if (vpn.country !== "") return (vpn.city !== "" ? vpn.city + ", " + vpn.country : vpn.country).toUpperCase()
    return phrase.toUpperCase()
  }

  readonly property var settingRows: Model.settingRows(vpn.config)
  readonly property var quickOptions: Model.quickConnectOptions()
  readonly property var countryList: Model.countryRows(vpn.countries, vpn.country, countryQuery)

  readonly property bool canAct: vpn.installed && !vpn.needsSignIn && !vpn.guiRunning

  // --- Cursor -----------------------------------------------------------------
  // Exactly one highlighted spot across the whole panel, addressed by
  // focusSection plus that section's index. Mouse hover and keyboard nav both
  // write this state at the root; no row ever reads containsMouse for visuals.
  property string focusSection: "header"
  property int quickIndex: 0
  property int settingIndex: 0
  property int countryIndex: 0
  property bool cursorActive: false
  property string countryQuery: ""

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  // Sections that have nothing in them are skipped by j/k rather than
  // presented as an empty stop.
  readonly property bool hasQuick: canAct
  readonly property bool hasSettings: canAct && settingRows.length > 0 && Object.keys(vpn.config).length > 0
  readonly property bool hasCountries: canAct && countryList.length > 0

  function sectionOrder() {
    var order = ["header"]
    if (hasQuick) order.push("quick")
    if (hasSettings) order.push("settings")
    if (hasCountries) order.push("countries")
    return order
  }

  function rowsIn(section) {
    if (section === "settings") return settingRows.length
    if (section === "countries") return countryList.length
    return 1
  }

  function indexIn(section) {
    if (section === "settings") return settingIndex
    if (section === "countries") return countryIndex
    return 0
  }

  function setIndexIn(section, value) {
    if (section === "settings") settingIndex = value
    else if (section === "countries") countryIndex = value
  }

  // Vertical movement walks rows inside the current section first, then steps
  // to the next section that actually exists.
  function moveCursor(dx, dy) {
    if (dx !== 0) {
      if (focusSection === "quick") quickIndex = Math.max(0, Math.min(quickOptions.length - 1, quickIndex + dx))
      return
    }
    if (dy === 0) return

    var order = sectionOrder()
    var at = order.indexOf(focusSection)
    if (at === -1) { focusSection = order[0]; return }

    var next = indexIn(focusSection) + dy
    if (next >= 0 && next < rowsIn(focusSection)) {
      setIndexIn(focusSection, next)
      return
    }

    var target = at + (dy > 0 ? 1 : -1)
    if (target < 0 || target >= order.length) return

    focusSection = order[target]
    // Entering a section from below lands on its last row, from above on its
    // first, so the cursor keeps travelling in the direction it was going.
    setIndexIn(focusSection, dy > 0 ? 0 : Math.max(0, rowsIn(focusSection) - 1))
  }

  function activateCursor() {
    if (focusSection === "header") { toggleVpn(); return }
    if (focusSection === "quick") {
      var option = quickOptions[quickIndex]
      if (option) vpn.quickConnect(option.id)
      return
    }
    if (focusSection === "settings") { cycleSetting(settingIndex); return }
    if (focusSection === "countries") {
      var country = countryList[countryIndex]
      if (country) connectCountry(country)
    }
  }

  function focusRow(section, index) {
    cursorActive = true
    focusSection = section
    setIndexIn(section, index)
  }

  function toggleVpn() {
    if (!vpn.installed) return
    if (vpn.needsSignIn) { vpn.signIn(); return }
    vpn.toggle()
  }

  function cycleSetting(index) {
    if (index < 0 || index >= settingRows.length) return
    var row = settingRows[index]
    vpn.applySetting(row.key, Model.nextSettingValue(row))
  }

  function connectCountry(country) {
    if (!country) return
    // Clicking the country you are already in is a reconnect request, which
    // the CLI handles as a fresh connect to the fastest server there.
    vpn.connectCountry(country.code, country.name)
  }

  function copyToClipboard(value) {
    if (!value) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(String(value)) + " | wl-copy"])
  }

  // --- Lifecycle --------------------------------------------------------------

  onOpenedChanged: {
    if (opened) {
      focusSection = "header"
      quickIndex = 0
      settingIndex = 0
      countryIndex = 0
      countryQuery = ""
      cursorActive = false
    }
  }

  // Availability shifts as the slow tier lands, so a section can vanish out
  // from under the cursor. Evacuate rather than leave it highlighting nothing.
  onCountryListChanged: {
    if (countryIndex >= countryList.length) countryIndex = Math.max(0, countryList.length - 1)
    if (!hasCountries && focusSection === "countries") focusSection = "header"
  }

  onSettingRowsChanged: {
    if (settingIndex >= settingRows.length) settingIndex = Math.max(0, settingRows.length - 1)
  }

  Timer {
    // Cycles the hero's flavour line, matching the Network and Tailscale
    // panels. Only runs while the panel is open and there is nothing more
    // useful to say on that line.
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: root.phraseIndex = (root.phraseIndex + 1) % root.phrases.length
  }

  IpcHandler {
    target: "jampick.protonvpn"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(): string { vpn.quickConnect("fastest"); return "ok" }
    function disconnect(): string { vpn.disconnect(); return "ok" }
    function toggleVpn(): string { root.toggleVpn(); return "ok" }
    function refresh(): string { vpn.refresh(); vpn.refreshDetails(true); return "ok" }
    function status(): string { return Model.stateLabel(root.vpnState) + (vpn.server !== "" ? " " + vpn.server : "") }
  }

  // --- Bar button -------------------------------------------------------------

  // The bar sizes each slot from its widget's implicit size (see Bar.qml's
  // ModuleSlot), and the base Panel is a bare Item with no size of its own, so
  // the button's size has to be forwarded up here or the slot collapses to
  // zero width and the widget silently never appears.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
    foreground: root.barIconColor

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleVpn()
      else if (buttonCode === Qt.MiddleButton) { vpn.refresh(); vpn.refreshDetails(true) }
      else root.toggle()
    }

    PanelToolTip {
      visible: button.tooltipHovered && !root.opened
      text: {
        var label = Model.stateLabel(root.vpnState)
        if (root.leaking) return label + " · " + vpn.leakReason
        if (vpn.connected && vpn.server !== "") return label + " · " + vpn.server
        return label
      }
      fontFamily: root.fontFamily
    }
  }

  // --- Panel ------------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(390))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The search field owns every key while it has focus, or typing a
      // country name would drive the cursor instead of filling the box.
      blocked: search.activeFocus

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "t" || t === "T") root.toggleVpn()
        else if (t === "r" || t === "R") { vpn.refresh(); vpn.refreshDetails(true) }
        else if (t === "d" || t === "D") vpn.disconnect()
        else if (t === "/") search.forceActiveFocus()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // --- Hero -------------------------------------------------------------
          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // Exposed for the hero's trailingControl, whose `root` resolves to
            // PanelHero rather than this Panel.
            readonly property bool ringVisible: root.headerHasCursor
            function focusHero() { root.focusRow("header", 0) }

            PanelHero {
              id: hero
              width: parent.width
              title: root.heroTitle
              meta: root.heroMeta
              detail: vpn.connected ? vpn.protocolEffective : ""
              foreground: root.leaking ? root.urgent : root.foreground
              fontFamily: root.fontFamily
              iconOpacity: root.vpnState === "protected" || root.leaking ? 1.0 : 0.5

              iconComponent: Component {
                Text {
                  text: root.icon
                  color: root.panelIconColor
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  visible: root.canAct
                  checked: vpn.active
                  busy: vpn.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: root.toggleVpn()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: vpn.active ? "Disconnect" : "Connect to the fastest server"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // --- Leak banner ------------------------------------------------------
          // The loudest thing in the panel, because it is the one state where
          // the user believes something untrue about their own machine.
          CursorSurface {
            visible: root.leaking
            width: parent.width
            implicitHeight: leakText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.urgent
            bordered: true

            Text {
              id: leakText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: "The tunnel is up but not protecting you. " + vpn.leakReason + "."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // --- Desktop app conflict ---------------------------------------------
          // The CLI and the GTK app refuse to run at the same time. Deliberately
          // not the urgent colour: the tunnel is fine and the bar icon above is
          // still accurate, it is only this panel's controls that are inert.
          CursorSurface {
            visible: vpn.guiRunning
            width: parent.width
            implicitHeight: guiText.implicitHeight + Style.spacing.rowPaddingX
            foreground: root.foreground
            bordered: true

            Text {
              id: guiText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              anchors.verticalCenter: parent.verticalCenter
              text: "The Proton VPN desktop app is open, and it will not share the command line. Close it to use these controls. The status above stays live either way."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // --- Action / error line ----------------------------------------------
          Text {
            visible: vpn.actionStatus !== "" || vpn.lastError !== ""
            width: parent.width
            text: vpn.actionStatus !== "" ? vpn.actionStatus : vpn.lastError
            color: vpn.lastError !== "" && vpn.actionStatus === "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // --- Not installed / signed out ---------------------------------------
          Button {
            visible: !vpn.installed
            width: parent.width
            text: "Install Proton VPN"
            tooltipText: "Runs omarchy pkg add proton-vpn-cli"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            onClicked: Quickshell.execDetached([
              "omarchy-launch-floating-terminal-with-presentation",
              "omarchy-pkg-add", "proton-vpn-cli", "proton-vpn-gtk-app"
            ])
          }

          Button {
            visible: vpn.installed && vpn.needsSignIn
            width: parent.width
            text: "Sign in to Proton VPN"
            tooltipText: "Opens a terminal for protonvpn signin"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            bordered: true
            onClicked: vpn.signIn()
          }

          // --- Connection details -----------------------------------------------
          Column {
            visible: vpn.connected
            width: parent.width
            spacing: Style.spacing.labelGap

            GridLayout {
              width: parent.width
              columns: 4
              columnSpacing: Style.space(20)
              rowSpacing: Style.spacing.labelGap

              // Every row stays mounted whether or not its number has arrived,
              // reading "--" until it has, so a late sample never reflows the
              // grid a second after the panel opens.
              InfoLabel { text: "Server load" }
              DetailValue {
                text: Model.formatLoad(vpn.load)
                color: {
                  var severity = Model.loadSeverity(vpn.load)
                  if (severity === "high") return root.urgent
                  if (severity === "medium") return root.foreground
                  return root.foreground
                }
              }
              InfoLabel { text: "IPv6" }
              DetailValue {
                // IPv6 escaping a tunnel is a classic leak, so the panel says
                // whether v6 is inside it rather than leaving it unanswered.
                text: vpn.info.ip6 ? "In tunnel" : "Not carried"
                color: root.foreground
              }

              InfoLabel { text: "Receiving" }
              DetailValue { text: vpn.hasTransferStats ? Model.formatRate(vpn.downloadRate) : "--" }
              InfoLabel { text: "Sending" }
              DetailValue { text: vpn.hasTransferStats ? Model.formatRate(vpn.uploadRate) : "--" }

              InfoLabel { text: "Exit IP" }
              DetailValue {
                text: vpn.info.exit_ip || "--"
                copyable: !!vpn.info.exit_ip
                tooltipText: "Copy exit IP"
              }
              InfoLabel { text: "Tunnel IP" }
              DetailValue {
                text: vpn.info.ip || "--"
                copyable: !!vpn.info.ip
                tooltipText: "Copy tunnel IP"
              }

              InfoLabel { text: "DNS" }
              DetailValue {
                text: vpn.info.dns || "none"
                color: vpn.info.dns ? root.foreground : root.urgent
                copyable: !!vpn.info.dns
                tooltipText: "Copy DNS server"
              }
              InfoLabel { text: "Routed" }
              DetailValue {
                text: vpn.info.routed === "1" ? "Yes" : "No"
                color: vpn.info.routed === "1" ? root.foreground : root.urgent
              }
            }
          }

          // --- Quick connect ----------------------------------------------------
          PanelSeparator {
            visible: root.hasQuick
            foreground: root.foreground
          }

          Column {
            visible: root.hasQuick
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "QUICK CONNECT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              id: quickRow
              width: parent.width
              spacing: Style.space(6)

              readonly property int count: Math.max(1, root.quickOptions.length)
              readonly property real cellWidth: (width - spacing * (count - 1)) / count

              // The wrapper takes modelData/index from the Repeater's delegate
              // context, which does not bind into nested `component`
              // declarations, and passes them down explicitly.
              Repeater {
                model: root.quickOptions

                delegate: Item {
                  required property var modelData
                  required property int index
                  width: quickRow.cellWidth
                  height: quickPill.implicitHeight

                  QuickPill {
                    id: quickPill
                    option: modelData
                    slot: index
                    width: parent.width
                  }
                }
              }
            }
          }

          // --- Protection settings ----------------------------------------------
          PanelSeparator {
            visible: root.hasSettings
            foreground: root.foreground
          }

          Column {
            visible: root.hasSettings
            width: parent.width
            spacing: Style.space(4)

            PanelSectionHeader {
              text: "PROTECTION"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bottomPadding: Style.space(4)
            }

            Repeater {
              model: root.settingRows

              delegate: Item {
                required property var modelData
                required property int index
                width: parent.width
                height: settingRow.implicitHeight

                SettingRow {
                  id: settingRow
                  row: modelData
                  slot: index
                  width: parent.width
                }
              }
            }
          }

          // --- Countries --------------------------------------------------------
          PanelSeparator {
            visible: root.canAct
            foreground: root.foreground
          }

          Item {
            visible: root.canAct
            width: parent.width
            implicitHeight: Math.max(countryHeader.implicitHeight, search.implicitHeight)

            PanelSectionHeader {
              id: countryHeader
              text: vpn.countries.length === 0 ? "LOADING COUNTRIES…" : "COUNTRIES"
              visible: root.canAct
              foreground: root.foreground
              fontFamily: root.fontFamily
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            TextField {
              id: search
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(150)
              placeholderText: "Filter…"
              text: root.countryQuery
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall

              onTextChanged: {
                root.countryQuery = text
                root.countryIndex = 0
              }

              // Escape hands keys back to the panel rather than closing it, so
              // the first Escape clears the search and the second one closes.
              Keys.onEscapePressed: function(event) {
                if (text !== "") text = ""
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
              Keys.onDownPressed: function(event) {
                root.focusRow("countries", 0)
                keyCatcher.forceActiveFocus()
                event.accepted = true
              }
              Keys.onReturnPressed: function(event) {
                if (root.countryList.length > 0) root.connectCountry(root.countryList[0])
                event.accepted = true
              }
            }
          }

          // Scrollable country list, height-capped so 100-plus countries do not
          // push the popup off-screen. ListView rather than Repeater+Column for
          // positionViewAtIndex, which is what keeps the keyboard-selected row
          // scrolled into view as j/k walk past the visible window.
          ListView {
            id: countryListView
            visible: root.hasCountries
            width: parent.width
            height: Math.min(contentHeight, Style.space(220))
            spacing: Style.space(4)
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            model: root.countryList
            currentIndex: root.focusSection === "countries" ? root.countryIndex : -1
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)

            delegate: Item {
              required property var modelData
              required property int index
              readonly property string sectionTitle: Model.countrySectionTitle(root.countryList, index)
              width: ListView.view.width
              height: delegateColumn.implicitHeight

              Column {
                id: delegateColumn
                width: parent.width
                spacing: Style.space(4)

                PanelSectionHeader {
                  visible: sectionTitle !== ""
                  text: sectionTitle
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  height: visible ? implicitHeight : 0
                }

                CountryRow {
                  country: modelData
                  slot: parent.parent.index
                  width: parent.width
                }
              }
            }
          }

          Text {
            visible: root.canAct && vpn.countries.length > 0 && root.countryList.length === 0
            width: parent.width
            text: "No country matches \"" + root.countryQuery + "\""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  // --- Components ---------------------------------------------------------------

  // One quick-connect pill. Same shape as the Network panel's band and DNS
  // pills: cursor and current visuals come entirely from the shared chrome,
  // this only binds them to the panel cursor.
  component QuickPill: Button {
    id: pill
    required property var option
    required property int slot

    text: option ? option.label : ""
    tooltipText: option ? option.hint : ""
    fontSize: Style.font.bodySmall
    foreground: root.foreground
    fontFamily: root.fontFamily
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
    bordered: true
    enabled: !vpn.busy

    // Lights up while its own connect is in flight, so the pill you clicked is
    // the one that looks busy.
    active: option ? vpn.pendingQuick === option.id : false
    hasCursor: root.cursorActive && root.focusSection === "quick" && root.quickIndex === slot

    onClicked: if (option) vpn.quickConnect(option.id)
    onHovered: function(isHovered) { if (isHovered) root.focusRow("quick", pill.slot) }
  }

  // One protection setting. Booleans get a switch; NetShield gets a value pill
  // because it has three states and a switch would have to lie about one of
  // them. Either way the whole row is the click target and one Enter cycles it,
  // so the keyboard model stays uniform across both shapes.
  component SettingRow: CursorSurface {
    id: settingItem
    required property var row
    required property int slot

    readonly property bool isBusy: vpn.pendingSetting === (row ? row.key : "")
    readonly property bool isSelected: root.focusSection === "settings" && root.settingIndex === slot

    hasCursor: root.cursorActive && isSelected
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: settingBody.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: !vpn.settingBusy

      onContainsMouseChanged: if (containsMouse) root.focusRow("settings", settingItem.slot)
      onClicked: {
        root.focusRow("settings", settingItem.slot)
        root.cycleSetting(settingItem.slot)
      }
    }

    Item {
      id: settingBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(settingLabels.implicitHeight, settingControl.implicitHeight)

      Column {
        id: settingLabels
        anchors.left: parent.left
        anchors.right: settingControl.left
        anchors.rightMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Text {
          width: parent.width
          text: settingItem.row ? settingItem.row.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: settingItem.row ? settingItem.row.description : ""
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Item {
        id: settingControl
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: Math.max(settingSwitch.visible ? settingSwitch.implicitWidth : 0,
                                settingValue.visible ? settingValue.implicitWidth : 0)
        implicitHeight: Math.max(settingSwitch.visible ? settingSwitch.implicitHeight : 0,
                                 settingValue.visible ? settingValue.implicitHeight : 0)

        ToggleSwitch {
          id: settingSwitch
          anchors.centerIn: parent
          visible: settingItem.row ? settingItem.row.boolean : false
          checked: settingItem.row ? settingItem.row.checked : false
          busy: settingItem.isBusy
          // The row owns the click, so the switch must not also claim it --
          // otherwise one click would cycle the value twice.
          interactive: false
          hasCursor: settingItem.hasCursor
          foreground: root.foreground
        }

        BorderSurface {
          id: settingValue
          anchors.centerIn: parent
          visible: settingItem.row ? !settingItem.row.boolean : false
          implicitWidth: settingValueText.implicitWidth + Style.space(14)
          implicitHeight: settingValueText.implicitHeight + Style.space(6)
          color: "transparent"
          radius: Style.cornerRadius
          borderSpec: Border.controlSpec(settingItem.hasCursor ? "hover-cursor" : "normal", root.foreground, Color.accent)

          Text {
            id: settingValueText
            anchors.centerIn: parent
            text: settingItem.isBusy ? "…" : Model.settingValueLabel(settingItem.row)
            // An unrecognised value means the CLI grew an option this widget
            // does not model. Show it rather than quietly rendering "Off".
            color: settingItem.row && !settingItem.row.known ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
      }
    }
  }

  // One country row. `current` marks the country you are connected to, which
  // the list pins to the top; clicking it reconnects to the fastest server
  // there, which is a legitimate thing to want.
  component CountryRow: CursorSurface {
    id: countryItem
    required property var country
    required property int slot

    readonly property bool isSelected: root.focusSection === "countries" && root.countryIndex === slot
    readonly property bool isBusy: vpn.pendingCountry === (country ? country.code : "")

    hasCursor: root.cursorActive && isSelected
    current: country ? country.connected : false
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: countryBody.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      enabled: !vpn.busy

      onContainsMouseChanged: if (containsMouse) root.focusRow("countries", countryItem.slot)
      onClicked: {
        root.focusRow("countries", countryItem.slot)
        root.connectCountry(countryItem.country)
      }
    }

    Item {
      id: countryBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.spacing.rowPaddingX
      anchors.rightMargin: Style.spacing.rowPaddingX
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: countryName.implicitHeight

      Text {
        id: countryName
        anchors.left: parent.left
        anchors.right: countryStatus.left
        anchors.rightMargin: Style.space(8)
        anchors.verticalCenter: parent.verticalCenter
        text: countryItem.country ? countryItem.country.name : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }

      Text {
        id: countryStatus
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        text: {
          if (countryItem.isBusy) return "Connecting…"
          if (countryItem.country && countryItem.country.connected) return "Connected"
          return countryItem.country ? countryItem.country.code : ""
        }
        color: countryItem.country && countryItem.country.connected ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component DetailValue: InfoValue {
    property bool copyable: false
    property string tooltipText: "Copy to clipboard"

    Layout.fillWidth: true
    horizontalAlignment: Text.AlignRight
    elide: Text.ElideRight

    MouseArea {
      id: valueMouse
      anchors.fill: parent
      enabled: copyable && parent.text !== ""
      hoverEnabled: enabled
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.copyToClipboard(parent.text)
    }

    PanelToolTip {
      visible: valueMouse.enabled && valueMouse.containsMouse
      text: tooltipText
      fontFamily: root.fontFamily
    }
  }
}
