import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "omarchy.agents"
  ipcTarget: "omarchy.agents"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Every subscription on one page, limits first: the question this panel
  // answers is how much room is left, and where.
  readonly property var providers: usage.enabledProviders

  property bool cursorActive: false

  // Countdowns and "as of" ages read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  // Every account of every provider that has more than one, in page order.
  // The keyboard picks one by its position; picking only looks, and Enter on
  // a picked account is what moves new sessions to it.
  readonly property var accountEntries: {
    var out = []
    for (var i = 0; i < providers.length; i++) {
      var list = providerAccounts(providers[i])
      if (list.length < 2) continue
      for (var j = 0; j < list.length; j++) out.push({ provider: providers[i], account: list[j] })
    }
    return out
  }
  property int accountCursor: -1
  readonly property var pickedEntry: accountCursor >= 0 && accountCursor < accountEntries.length ? accountEntries[accountCursor] : null

  // The bar icon lights up when any account new sessions use is nearly out,
  // or a prepaid balance is down to its last 10%.
  readonly property bool alarming: {
    for (var i = 0; i < providers.length; i++) {
      var window = bindingWindow(providers[i])
      if (window && window.percent >= 0.9) return true
      if (balanceAlarming(providers[i].balance)) return true
    }
    return false
  }

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // A provider's accounts, when it has any. The list arrives as a sequence
  // rather than a JS array once it has passed through a model, so it's
  // judged by its length.
  function providerAccounts(p) {
    return p && p.accounts && p.accounts.length > 0 ? p.accounts : []
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function addAccount() {
    root.close()
    Util.execArgv(["omarchy-menu", "summon", "setup.accounts.add"])
  }

  function renameAccount(p, account, label) {
    if (!p || !account) return
    Util.execArgv(["omarchy-agent-account-rename", p.providerId, String(account.id), label])
  }

  function useAccount(p, account) {
    if (!p || !account || account.active) return
    Util.execArgv(["omarchy-agent-account-use", p.providerId, String(account.id)])
  }

  function autoSwitchFor(p) {
    return !!p && !!p.accountSwitch && p.accountSwitch.mode === "auto"
  }

  function switchThreshold(p) {
    return p && p.accountSwitch ? Number(p.accountSwitch.threshold || 95) : 95
  }

  function setSwitchMode(p, mode) {
    if (!p || providerAccounts(p).length < 2 || mode === (autoSwitchFor(p) ? "auto" : "manual")) return
    Util.execArgv(["bash", "-c", 'omarchy-agent-account-mode "$1" "$2" >/dev/null && omarchy-agent-usage-update --limits-only "$1"',
                   "omarchy-agent-account-mode", p.providerId, mode])
  }

  // `m` flips autoswitch for the picked account's provider, or the first
  // provider with several accounts when nothing is picked.
  function toggleSwitchMode() {
    var p = pickedEntry ? pickedEntry.provider : (accountEntries.length > 0 ? accountEntries[0].provider : null)
    if (p) setSwitchMode(p, autoSwitchFor(p) ? "manual" : "auto")
  }

  function activateSelection() {
    if (pickedEntry && !pickedEntry.account.active)
      useAccount(pickedEntry.provider, pickedEntry.account)
    else
      refreshNow()
  }

  function isPicked(p, account) {
    return !!pickedEntry && !!p && !!account
      && pickedEntry.provider.providerId === p.providerId && pickedEntry.account.id === account.id
  }

  // Hands the keyboard back to the panel after an inline edit.
  function focusKeys() {
    keyCatcher.forceActiveFocus()
  }

  function accountDetail(account) {
    var parts = []
    if (String(account.email || "") !== "") parts.push(account.email)
    if (String(account.plan || "") !== "") parts.push(account.plan)
    if (account.resetCredits && Number(account.resetCredits.available) > 0)
      parts.push(account.resetCredits.available + " free reset" + (Number(account.resetCredits.available) === 1 ? "" : "s"))
    if (account.stale === true) {
      var ageMs = Number(account.fetchedAt) > 0 ? nowMs - Number(account.fetchedAt) : 0
      var age = ageMs > 60000 ? "as of " + formatDuration(ageMs) + " ago" : "last known"
      parts.push(String(account.usageStatusText || "") !== "" ? account.usageStatusText + " · " + age : age)
    }
    return parts.join(" · ")
  }

  function resetCreditsText(credits) {
    if (!credits || !(Number(credits.available) > 0)) return ""
    var count = Number(credits.available)
    var text = count + " free reset" + (count === 1 ? "" : "s")
    var expires = new Date(String(credits.nextExpiresAt || "")).getTime()
    if (isFinite(expires) && expires > nowMs) text += " · next expires in " + formatDuration(expires - nowMs)
    return text
  }

  function planLabel(p) {
    var tier = String(p && p.tierLabel || "")
    return tier === "" ? "" : tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // A model-scoped window ("Fable Weekly") is its own allowance, but it runs
  // on the same clock as the window it's named for, so it's shown attached to
  // that row rather than as a row of its own. One with nothing to attach to
  // still gets its own row.
  function scopedPart(title) {
    var match = String(title || "").match(/^(.+) (Session|Weekly|Monthly)$/)
    return match ? { model: match[1], window: match[2] } : null
  }

  function displayWindows(p) {
    var windows = limitWindows(p)
    var out = []
    var byTitle = {}
    for (var i = 0; i < windows.length; i++) {
      if (scopedPart(windows[i].title)) continue
      windows[i].scoped = []
      out.push(windows[i])
      byTitle[windows[i].title] = windows[i]
    }
    for (var j = 0; j < windows.length; j++) {
      var part = scopedPart(windows[j].title)
      if (!part) continue
      var base = byTitle[part.window]
      if (base) {
        base.scoped.push({ title: part.model, percent: windows[j].percent, resetAt: windows[j].resetAt })
      } else {
        windows[j].scoped = []
        out.push(windows[j])
      }
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  function balanceAlarming(b) {
    return !!b && b.funded > 0 && b.remaining / b.funded <= 0.1
  }

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- summary
  //
  // The hero's line rotates through what the token counts add up to across
  // every agent, now that they no longer get charts of their own.

  readonly property var summaryPhrases: {
    var rev = usage.dataRevision
    var week = 0
    var today = 0
    var prompts = 0
    var sessions = 0
    var byDay = {}
    var byModel = {}
    for (var i = 0; i < providers.length; i++) {
      var p = providers[i]
      var days = p.recentDays || []
      for (var d = 0; d < days.length; d++) {
        var tokens = Number(days[d].messageCount || 0)
        week += tokens
        byDay[days[d].date] = (byDay[days[d].date] || 0) + tokens
      }
      today += Number(p.todayTotalTokens || 0)
      if (p.hasPromptStats !== false) {
        prompts += Number(p.todayPrompts || 0)
        sessions += Number(p.todaySessions || 0)
      }
      var models = p.modelUsage || {}
      for (var id in models) {
        var bucket = models[id] || {}
        var total = Number(bucket.inputTokens || 0) + Number(bucket.outputTokens || 0)
          + Number(bucket.cacheReadInputTokens || 0) + Number(bucket.cacheCreationInputTokens || 0)
        var name = usage.friendlyModelName(id)
        byModel[name] = (byModel[name] || 0) + total
      }
    }

    var phrases = []
    if (week > 0) phrases.push(usage.formatTokenCount(week) + " tokens this week")
    if (today > 0) phrases.push(usage.formatTokenCount(today) + " tokens today")
    var topModel = ""
    for (var model in byModel) if (topModel === "" || byModel[model] > byModel[topModel]) topModel = model
    if (topModel !== "" && byModel[topModel] > 0) phrases.push("Mostly " + topModel)
    var busiest = ""
    for (var date in byDay) if (busiest === "" || byDay[date] > byDay[busiest]) busiest = date
    if (busiest !== "" && byDay[busiest] > 0) phrases.push("Busiest day: " + dayName(busiest))
    if (prompts > 0) phrases.push(prompts + " prompt" + (prompts === 1 ? "" : "s") + " today")
    if (sessions > 0) phrases.push(sessions + " session" + (sessions === 1 ? "" : "s") + " today")
    return phrases
  }
  property int phraseIndex: 0
  readonly property string heroPhrase: summaryPhrases.length > 0
    ? summaryPhrases[phraseIndex % summaryPhrases.length]
    : (providers.length > 0 ? "Subscriptions" : "No usage yet")

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][parsed.getDay()]
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    for (var i = 0; i < providers.length; i++) {
      var count = Number(providers[i].syncDeviceCount || 0)
      if (providers[i].syncEnabled && count > 0)
        return "Merged from " + count + " device" + (count === 1 ? "" : "s")
    }
    return ""
  }

  // Agents that ship a white mark carry an `assets/<id>-light.svg` twin for
  // light surfaces; marks that work on both (Claude's brand-orange) ship one
  // file. The luminance check decides which candidate to try first.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Marks resolve by convention, so a new agent's data file needs nothing
  // from this panel: assets/<id>.svg if it ships one, the module's bar glyph
  // if it doesn't.
  function iconCandidatesForProvider(p, surfaceColor) {
    if (!p) return []
    var candidates = []
    if (colorLuminance(surfaceColor || Color.background) >= 0.5)
      candidates.push(Qt.resolvedUrl("assets/" + p.providerId + "-light.svg"))
    candidates.push(Qt.resolvedUrl("assets/" + p.providerId + ".svg"))
    return candidates
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    accountCursor = -1
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    interval: 2800
    running: root.opened && root.summaryPhrases.length > 1
    repeat: true
    onTriggered: phraseSwap.restart()
  }

  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 0.0; duration: Style.duration(180); easing.type: Easing.OutQuad
    }
    ScriptAction {
      script: root.phraseIndex = (root.phraseIndex + 1) % Math.max(1, root.summaryPhrases.length)
    }
    PropertyAnimation {
      target: hero; property: "metaOpacity"
      to: 1.0; duration: Style.duration(260); easing.type: Easing.InQuad
    }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.refreshNow()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.activateSelection()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if (t === "a" || t === "A") root.addAccount()
        else if (t === "m" || t === "M") root.toggleSwitchMode()
        else if (t >= "1" && t <= "9" && Number(t) <= root.accountEntries.length) root.accountCursor = Number(t) - 1
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
        ScrollBar.vertical: ScrollBar {
          id: panelScroll
          policy: ScrollBar.AsNeeded
        }

        Column {
          id: column
          // When the panel scrolls, the bar gets its own strip rather than
          // sitting on top of the right-aligned numbers.
          width: panelFlick.width - (panelFlick.interactive ? panelScroll.width + Style.space(6) : 0)
          spacing: Style.space(16)

          // ---------- Hero: agents · rotating summary · add ----------
          PanelHero {
            id: hero
            width: parent.width
            title: "Agents"
            meta: root.heroPhrase
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: button.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            trailingControl: Component {
              TextLink {
                text: "+"
                font.pixelSize: Style.font.heading
                tooltip: "Add a subscription"
                onClicked: root.addAccount()
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.providers

            ProviderSection {
              required property var modelData
              width: column.width
              provider: modelData
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // One provider: its mark, name, and plan, then its limits — or, with
  // several accounts, each account's name, state, and limits in turn. A
  // prepaid provider shows its balance instead.
  component ProviderSection: Column {
    id: section
    property var provider: null
    readonly property var accounts: root.providerAccounts(provider)
    readonly property bool multi: accounts.length > 1
    readonly property var windows: root.displayWindows(provider)
    readonly property var balance: provider ? (provider.balance || null) : null
    spacing: Style.space(16)

    PanelSeparator { foreground: root.foreground }

    Item {
      width: parent.width
      implicitHeight: Math.max(sectionMark.height, sectionName.implicitHeight)

      ProviderIcon {
        id: sectionMark
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        provider: section.provider
      }

      Text {
        id: sectionName
        anchors.left: sectionMark.right
        anchors.leftMargin: Style.space(10)
        anchors.verticalCenter: parent.verticalCenter
        text: section.provider ? section.provider.providerName : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        visible: !section.multi
        text: root.planLabel(section.provider)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // Sign-in and endpoint trouble for a single-account provider; with
    // several, each account says so on its own line.
    Text {
      visible: !section.multi && !!section.provider && String(section.provider.usageStatusText || "") !== ""
      width: parent.width
      text: section.provider ? String(section.provider.authHelpText || "") : ""
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    Column {
      visible: !section.multi && section.windows.length > 0
      width: parent.width
      spacing: Style.space(12)

      Repeater {
        model: section.multi ? [] : section.windows

        CompactLimit {
          required property var modelData
          width: section.width
          window: modelData
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: root.resetCreditsText(section.provider ? section.provider.resetCredits : null)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    // The meter shows what is left, not what is used: a prepaid account
    // drains toward empty rather than filling toward a cap.
    Column {
      visible: !!section.balance
      width: parent.width
      spacing: Style.space(6)

      Item {
        width: parent.width
        implicitHeight: balanceTitle.implicitHeight

        Text {
          id: balanceTitle
          textFormat: Text.PlainText
          width: parent.width * 0.3
          anchors.verticalCenter: parent.verticalCenter
          text: "Balance"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Meter {
          anchors.left: balanceTitle.right
          anchors.right: balanceValue.left
          anchors.rightMargin: Style.spacing.md
          anchors.verticalCenter: parent.verticalCenter
          value: section.balance && section.balance.funded > 0 ? section.balance.remaining / section.balance.funded : -1
          alarming: root.balanceAlarming(section.balance)
        }

        Text {
          id: balanceValue
          textFormat: Text.PlainText
          width: Style.space(96)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignRight
          text: section.balance ? root.formatMoney(section.balance.remaining, section.balance.currency) : ""
          color: root.balanceAlarming(section.balance) ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: root.balanceDetailText(section.balance)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }

    Repeater {
      model: section.multi ? section.accounts : []

      Column {
        id: accountBlock
        required property var modelData
        required property int index
        width: section.width
        topPadding: index > 0 ? Style.space(6) : 0
        spacing: Style.space(14)

        AccountHeader {
          width: parent.width
          account: accountBlock.modelData
          owner: section.provider
          picked: root.isPicked(section.provider, accountBlock.modelData)
        }

        Column {
          width: parent.width
          spacing: Style.space(12)

          Repeater {
            model: root.displayWindows({ limits: accountBlock.modelData.limits || [] })

            CompactLimit {
              required property var modelData
              width: accountBlock.width
              window: modelData
            }
          }
        }
      }
    }
  }

  // A provider's mark, falling back to the bar glyph when it ships none.
  component ProviderIcon: Item {
    id: mark
    property var provider: null
    property var candidates: root.iconCandidatesForProvider(provider, root.surface)
    property string candidatesKey: candidates.join("\n")
    property int candidateIndex: 0
    onCandidatesKeyChanged: candidateIndex = 0

    width: Style.font.heading
    height: Style.font.heading

    Image {
      id: markImage
      anchors.fill: parent
      source: mark.candidateIndex < mark.candidates.length ? mark.candidates[mark.candidateIndex] : ""
      sourceSize.width: Style.font.heading * 2
      sourceSize.height: Style.font.heading * 2
      fillMode: Image.PreserveAspectFit
      // Advancing source from inside its own status change trips the
      // binding-loop detector; defer the step one tick.
      onStatusChanged: if (status === Image.Error && mark.candidateIndex < mark.candidates.length)
        Qt.callLater(function() { mark.candidateIndex++ })
    }

    Text {
      anchors.centerIn: parent
      visible: markImage.status !== Image.Ready
      text: button.text
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
    }
  }

  // A plain-text control: dim until hovered or picked, accent when it's the
  // current choice. Stands in for bordered buttons, which pile up here.
  component TextLink: Text {
    id: link
    signal clicked()
    property bool current: false
    property bool picked: false
    property string tooltip: ""
    readonly property bool hot: linkMouse.containsMouse || picked
    textFormat: Text.PlainText
    color: current ? Color.accent : (hot ? root.foreground : root.dim)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.bold: current
    font.underline: hot && !current

    MouseArea {
      id: linkMouse
      anchors.fill: parent
      anchors.margins: -Style.space(4)
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: link.clicked()
    }

    PanelToolTip {
      visible: link.tooltip !== "" && linkMouse.containsMouse
      text: link.tooltip
    }
  }

  // An account's name, email and plan, with ACTIVE or a Use link on the
  // right. Clicking the name edits it in place: Enter renames, Esc or
  // clicking away leaves it as it was.
  component AccountHeader: Item {
    id: head
    property var account: ({})
    property var owner: null
    property bool picked: false
    property bool editing: false
    // The new name shows at once; the record catches up a moment later.
    property string renamedTo: ""
    readonly property bool isActive: account.active === true
    readonly property bool autoOn: root.autoSwitchFor(owner)
    readonly property string label: renamedTo !== "" ? renamedTo : String(account.label || account.id || "")

    onAccountChanged: renamedTo = ""
    implicitHeight: Math.max(headText.implicitHeight, headAction.implicitHeight)

    function startRename() {
      editing = true
      nameField.text = label
      nameField.forceActiveFocus()
      nameField.selectAll()
    }

    function finishRename(save) {
      if (!editing) return
      var value = nameField.text.trim()
      editing = false
      root.focusKeys()
      if (save && value !== "" && value !== label) {
        renamedTo = value
        root.renameAccount(owner, account, value)
      }
    }

    Column {
      id: headText
      anchors.left: parent.left
      anchors.right: headAction.left
      anchors.rightMargin: Style.spacing.sm
      spacing: Style.space(4)

      Text {
        id: nameText
        textFormat: Text.PlainText
        visible: !head.editing
        width: Math.min(implicitWidth, parent.width)
        text: head.label
        color: head.picked ? Color.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: head.isActive
        font.underline: nameMouse.containsMouse
        elide: Text.ElideRight

        MouseArea {
          id: nameMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.IBeamCursor
          onClicked: head.startRename()
        }
      }

      TextField {
        id: nameField
        visible: head.editing
        width: parent.width
        foreground: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        horizontalPadding: Style.space(4)
        verticalPadding: Style.space(1)
        onAccepted: head.finishRename(true)
        onActiveFocusChanged: if (!activeFocus) head.finishRename(false)
        Keys.onEscapePressed: function(event) {
          head.finishRename(false)
          event.accepted = true
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: text !== ""
        width: parent.width
        text: root.accountDetail(head.account)
        // Numbers kept from an earlier check are normal; a sign-in that
        // needs attention is not.
        color: String(head.account.usageStatusText || "") !== "" ? root.urgent : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Item {
      id: headAction
      anchors.right: parent.right
      anchors.top: parent.top
      implicitWidth: head.isActive ? headActive.implicitWidth : useRow.implicitWidth
      implicitHeight: head.isActive ? headActive.implicitHeight : useRow.implicitHeight

      Text {
        id: headActive
        visible: head.isActive
        anchors.right: parent.right
        text: "ACTIVE"
        color: Color.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }

      // Switching now is Use. Hovering it also offers Autoswitch: move new
      // sessions over by themselves once the active account reaches the
      // threshold. While that's on it stays in view, and clicking it again
      // goes back to only being notified.
      Row {
        id: useRow
        visible: !head.isActive
        anchors.right: parent.right
        spacing: Style.space(12)

        HoverHandler { id: useHover }

        TextLink {
          visible: head.autoOn || useHover.hovered || head.picked
          text: "Autoswitch"
          current: head.autoOn
          tooltip: head.autoOn
            ? "Stop switching automatically"
            : "Switch here automatically at " + root.switchThreshold(head.owner) + "%"
          onClicked: root.setSwitchMode(head.owner, head.autoOn ? "manual" : "auto")
        }

        TextLink {
          text: head.picked ? "Use ⏎" : "Use"
          picked: head.picked
          onClicked: root.useAccount(head.owner, head.account)
        }
      }
    }
  }

  // One line per limit window: title, meter, percentage, and reset. A
  // model-scoped allowance on the same clock ("Fable" on Weekly) is a marker
  // on this row's meter, named in the row's tooltip.
  component CompactLimit: Item {
    id: compact
    property var window: null
    readonly property var scoped: window && window.scoped ? window.scoped : []
    readonly property bool alarming: window && window.percent >= 0.9
    readonly property real resetMs: root.resetMsFor(window)
    implicitHeight: compactTitle.implicitHeight

    HoverHandler { id: compactHover }

    PanelToolTip {
      visible: compactHover.hovered && compact.scoped.length > 0
      text: {
        var lines = []
        for (var i = 0; i < compact.scoped.length; i++)
          lines.push(compact.scoped[i].title + ": " + Math.round(compact.scoped[i].percent * 100) + "% of its "
            + String(compact.window ? compact.window.title : "").toLowerCase() + " allowance")
        return lines.join("\n")
      }
    }

    Text {
      id: compactTitle
      textFormat: Text.PlainText
      width: parent.width * 0.3
      anchors.verticalCenter: parent.verticalCenter
      text: compact.window ? compact.window.title : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Meter {
      anchors.left: compactTitle.right
      anchors.right: compactValue.left
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      value: compact.window ? compact.window.percent : -1
      alarming: compact.alarming
      markers: compact.scoped
    }

    Text {
      id: compactValue
      textFormat: Text.PlainText
      width: Style.space(96)
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      text: (compact.window ? Math.round(compact.window.percent * 100) + "%" : "—")
        + (compact.resetMs > 0 ? "  " + root.formatDuration(compact.resetMs) : "")
      color: compact.alarming ? root.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    // Other allowances on the same clock, drawn as ticks across the track.
    property var markers: []

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: Style.duration(160); easing.type: Easing.OutCubic }
      }
    }

    Repeater {
      model: meter.markers

      Rectangle {
        required property var modelData
        width: Math.max(2, Math.round(meter.thickness * 0.5))
        height: meter.thickness * 2.5
        radius: width / 2
        anchors.verticalCenter: meterTrack.verticalCenter
        x: root.clamp(meterTrack.width * root.clamp(Number(modelData.percent), 0, 1) - width / 2, 0, meterTrack.width - width)
        color: Number(modelData.percent) >= 0.9 ? root.urgent : Color.accent
      }
    }
  }
}
