# onehand: bottom-anchored NTP, bottom tab-switcher toolbar (mirrored), bottom-anchored tab grid.
# Run from chromium/src by patch.sh. Each file is edited all-or-nothing; failures only print ::warning::.
import sys

HUB = "chrome/browser/hub/internal/android"
TAB = "chrome/android/features/tab_ui/java/src/org/chromium/chrome/browser/tasks/tab_management"
NTP = "chrome/android/java"

edits = {}  # path -> list of (old, new)
def edit(path, old, new):
    edits.setdefault(path, []).append((old, new))

# ---- 1. New tab page: stack the content (logo, search box, tiles) against the bottom of the page.
edit(f"{NTP}/res/layout/new_tab_page_layout.xml",
     'android:gravity="center"', 'android:gravity="center_horizontal|bottom"')
edit(f"{NTP}/res/layout/new_tab_page_layout.xml",
     'android:layout_height="0dp"\n        android:layout_weight="1"\n        android:visibility="gone" />',
     'android:layout_height="0dp"\n        android:layout_weight="0"\n        android:visibility="gone" />')
# The header is a wrap_content row of the feed list; make it at least as tall as the list so gravity=bottom has room.
edit(f"{NTP}/src/org/chromium/chrome/browser/ntp/NewTabPageLayout.java",
     "        super.onMeasure(widthMeasureSpec, heightMeasureSpec);\n    }\n",
     "        super.onMeasure(widthMeasureSpec, heightMeasureSpec);\n"
     "        // onehand: fill the viewport so the content can be anchored to the bottom.\n"
     "        if (getParent() instanceof View) {\n"
     "            View parentView = (View) getParent();\n"
     "            int parentHeight =\n"
     "                    parentView.getMeasuredHeight()\n"
     "                            - parentView.getPaddingTop()\n"
     "                            - parentView.getPaddingBottom();\n"
     "            if (parentHeight > getMeasuredHeight()) {\n"
     "                setMeasuredDimension(getMeasuredWidth(), parentHeight);\n"
     "            }\n"
     "        }\n"
     "    }\n")

# ---- 2. Tab switcher (hub): toolbar to the bottom, plus button on the right, menu on the left.
edit(f"{HUB}/res/layout/hub_layout.xml",
     'android:layout_marginTop="@dimen/toolbar_height_no_shadow">',
     'android:layout_marginBottom="@dimen/toolbar_height_no_shadow">')
edit(f"{HUB}/res/layout/hub_layout.xml",
     '<include layout="@layout/hub_toolbar_layout" />',
     '<include layout="@layout/hub_toolbar_layout"\n'
     '      android:layout_width="match_parent"\n'
     '      android:layout_height="wrap_content"\n'
     '      android:layout_gravity="bottom" />')
edit(f"{HUB}/res/layout/hub_toolbar_layout.xml",
     'android:layout_gravity="start|center_vertical">',
     'android:layout_gravity="end|center_vertical"\n'
     '        android:layout_marginEnd="@dimen/hub_toolbar_action_button_start_margin">')
edit(f"{HUB}/res/layout/hub_toolbar_layout.xml",
     'android:layout_width="@dimen/hub_toolbar_action_button_start_margin"',
     'android:layout_width="0dp"')
edit(f"{HUB}/res/layout/hub_toolbar_layout.xml",
     'android:layout_gravity="end" >', 'android:layout_gravity="start" >')

HC = f"{HUB}/java/src/org/chromium/chrome/browser/hub/HubCoordinator.java"
edit(HC, "import android.os.Handler;\n",
     "import android.os.Build;\nimport android.os.Handler;\n")
edit(HC, "import android.view.ViewGroup;\n",
     "import android.view.ViewGroup;\nimport android.view.WindowInsets;\n")
edit(HC,
     "        hubToolbarView.setXrSpaceModeObservableSupplier(xrSpaceModeObservableSupplier);\n",
     "        hubToolbarView.setXrSpaceModeObservableSupplier(xrSpaceModeObservableSupplier);\n"
     "        // onehand: the toolbar is at the bottom, keep it (and the pane host) above the navigation bar.\n"
     "        final View onehandPaneHost = mContainerView.findViewById(R.id.hub_pane_host_container);\n"
     "        final int onehandBaseBottomMargin =\n"
     "                ((ViewGroup.MarginLayoutParams) onehandPaneHost.getLayoutParams()).bottomMargin;\n"
     "        hubToolbarView.setOnApplyWindowInsetsListener(\n"
     "                (v, insets) -> {\n"
     "                    int bottomInset = getOnehandBottomInset(insets);\n"
     "                    v.setPadding(\n"
     "                            v.getPaddingLeft(), v.getPaddingTop(), v.getPaddingRight(), bottomInset);\n"
     "                    ViewGroup.MarginLayoutParams lp =\n"
     "                            (ViewGroup.MarginLayoutParams) onehandPaneHost.getLayoutParams();\n"
     "                    lp.bottomMargin = onehandBaseBottomMargin + bottomInset;\n"
     "                    onehandPaneHost.setLayoutParams(lp);\n"
     "                    return insets;\n"
     "                });\n"
     "        hubToolbarView.requestApplyInsets();\n")
edit(HC,
     "    /** Returns the view group to contain the snackbar. */\n",
     "    @SuppressWarnings(\"deprecation\")\n"
     "    private static int getOnehandBottomInset(WindowInsets insets) {\n"
     "        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {\n"
     "            return insets.getInsets(WindowInsets.Type.navigationBars()).bottom;\n"
     "        }\n"
     "        return insets.getSystemWindowInsetBottom();\n"
     "    }\n\n"
     "    /** Returns the view group to contain the snackbar. */\n")

# ---- 3. Tab switcher: main tab grid stacks up from the bottom (tab group dialog / multi-select editor untouched).
edit(f"{TAB}/TabSwitcherPaneCoordinator.java",
     "            TabListRecyclerView recyclerView = tabListCoordinator.getContainerView();\n",
     "            TabListRecyclerView recyclerView = tabListCoordinator.getContainerView();\n"
     "            // onehand: anchor the main tab grid to the bottom.\n"
     "            if (recyclerView.getLayoutManager()\n"
     "                    instanceof androidx.recyclerview.widget.LinearLayoutManager) {\n"
     "                ((androidx.recyclerview.widget.LinearLayoutManager) recyclerView.getLayoutManager())\n"
     "                        .setStackFromEnd(true);\n"
     "            }\n")

ok = True
for path, lst in edits.items():
    try:
        with open(path, encoding="utf-8", newline="") as f:
            text = f.read()
    except OSError as e:
        print(f"::warning::onehand: cannot read {path}: {e}"); ok = False; continue
    if "onehand:" in text:
        print(f"onehand: {path} already patched, skipping"); continue
    crlf = "\r\n" in text
    if crlf: text = text.replace("\r\n", "\n")
    bad = [o for o, _ in lst if text.count(o) != 1]
    if bad:
        print(f"::warning::onehand: {path}: {len(bad)} anchor(s) missing or not unique, file left unchanged"
              f" (first: {bad[0][:70]!r}, matches: {text.count(bad[0])})")
        ok = False; continue
    for o, n in lst: text = text.replace(o, n, 1)
    if crlf: text = text.replace("\n", "\r\n")
    with open(path, "w", encoding="utf-8", newline="") as f: f.write(text)
    print(f"onehand: patched {path} ({len(lst)} edits)")
print("onehand: ALL EDITS APPLIED" if ok else "::warning::onehand: some edits were NOT applied, see above")
