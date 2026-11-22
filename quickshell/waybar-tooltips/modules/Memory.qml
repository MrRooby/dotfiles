// custom/memory: RAM split into anonymous and cache, how the swap is backed,
// commit charge, pressure and what the kernel keeps for itself. Same figures,
// order and thresholds as scripts/memory.sh, read every two seconds while
// the popup is open:
//   RAM, swap totals, commit, kernel   /proc/meminfo
//   swap devices                       /proc/swaps
//   zram contents and algorithm        /sys/block/zramN/{mm_stat,comp_algorithm}
//   pressure                           /proc/pressure/memory (avg10)
//
// Used is MemTotal - MemAvailable, as in the script and htop.

import QtQuick
import Quickshell
import Quickshell.Io
import qs

Column {
	id: view

	property string align: "center"
	property var d: null
	readonly property bool ready: d !== null
	readonly property int rowCount: d ? d.rows.length : 0

	// the font is monospaced: columns are sized in characters, like the
	// script pads them
	readonly property real charW: digit.advanceWidth
	readonly property real labelW: (d?.labelChars ?? 9) * charW
	readonly property real valueW: (d?.valueChars ?? 8) * charW
	readonly property real pctW: 4 * charW
	readonly property real meterW: width - labelW - 16 - valueW - 10 - 8 - pctW

	width: 370
	spacing: 7

	TextMetrics {
		id: digit
		font.family: Theme.font
		font.pixelSize: Theme.fontSize
		font.bold: true
		text: "0"
	}

	FileView { id: meminfo; path: "/proc/meminfo"; blockLoading: true }
	FileView { id: swaps; path: "/proc/swaps"; blockLoading: true; printErrors: false }
	FileView { id: pressure; path: "/proc/pressure/memory"; blockLoading: true; printErrors: false }

	// one FileView per zram device: re-pointing a single one inside the same
	// call keeps returning the first file it read
	Instantiator {
		id: zramStat
		model: 8
		delegate: FileView {
			required property int index
			path: "/sys/block/zram" + index + "/mm_stat"
			blockLoading: true
			printErrors: false
		}
	}
	Instantiator {
		id: zramAlg
		model: 8
		delegate: FileView {
			required property int index
			path: "/sys/block/zram" + index + "/comp_algorithm"
			blockLoading: true
			printErrors: false
		}
	}

	// ---- formatting, ported from memory.sh -------------------------------

	// kibibytes -> "11.9 GiB", integer rounding as in the script
	function human(k) {
		k = Math.max(0, k);
		let v, unit;
		if (k >= 1073741824) { v = Math.floor((k * 10 + 536870912) / 1073741824); unit = "TiB"; }
		else if (k >= 1048576) { v = Math.floor((k * 10 + 524288) / 1048576); unit = "GiB"; }
		else if (k >= 1024) { v = Math.floor((k * 10 + 512) / 1024); unit = "MiB"; }
		else if (k > 0) { v = k * 10; unit = "KiB"; }
		else return "0 B";
		return Math.floor(v / 10) + "." + (v % 10) + " " + unit;
	}
	function humanb(b) { return human(Math.floor(b / 1024)); }

	// "14.3 / 38.7 GiB": the unit only once when both sides share it
	function pair(a, b) {
		const x = human(a), y = human(b);
		const ux = x.split(" ").pop(), uy = y.split(" ").pop();
		return ux === uy ? x.slice(0, x.lastIndexOf(" ")) + " / " + y : x + " / " + y;
	}

	function percent(part, whole) {
		return whole > 0 ? Math.floor((part * 100 + Math.floor(whole / 2)) / whole) : 0;
	}

	// ---- sampling ----------------------------------------------------------

	function sample() {
		meminfo.reload();
		const mem = {};
		for (const line of meminfo.text().split("\n")) {
			const f = line.split(/:?\s+/);
			if (f.length >= 2)
				mem[f[0]] = Number(f[1]) || 0;
		}
		const m = key => mem[key] ?? 0;

		const total = m("MemTotal");
		const avail = m("MemAvailable");
		const used = Math.max(0, total - avail);
		const pct = percent(used, total);

		const swapTotal = m("SwapTotal");
		const swapUsed = Math.max(0, swapTotal - m("SwapFree"));

		// one row per active swap; a zram device says what it holds and the
		// RAM that really cost
		const swapRows = [];
		swaps.reload();
		for (const line of swaps.text().split("\n")) {
			const f = line.trim().split(/\s+/);
			if (f[0] === "Filename" || f.length < 4 || !/^[0-9]+$/.test(f[2]))
				continue;
			const name = f[0].slice(f[0].lastIndexOf("/") + 1);
			let detail = "";

			const zm = /^\/dev\/zram([0-9]+)$/.exec(f[0]);
			const n = zm ? Number(zm[1]) : -1;
			if (n >= 0 && n < zramStat.count) {
				const st = zramStat.objectAt(n);
				st.reload();
				const mm = st.text().trim().split(/\s+/).map(Number);
				const orig = mm[0] || 0, memused = mm[2] || 0;
				if (st.loaded && orig > 0) {
					detail = humanb(orig) + " in " + humanb(memused);
					if (memused > 0) {
						const r = Math.floor((orig * 10 + Math.floor(memused / 2)) / memused);
						detail += " · " + Math.floor(r / 10) + "." + (r % 10) + "×";
					}
					// "lzo-rle lzo lz4 [zstd] deflate": the bracketed one is in force
					const al = zramAlg.objectAt(n);
					al.reload();
					const am = /\[([^\]]+)\]/.exec(al.text());
					if (am)
						detail += " · " + am[1];
				}
			}
			if (detail === "")
				detail = human(Number(f[3])) + " of " + human(Number(f[2]));
			swapRows.push({ k: "T", a: name, b: detail });
		}

		// PSI avg10: "some" is any task stalled on memory, "full" all at once
		let psi = "";
		pressure.reload();
		const ptext = pressure.text();
		if (pressure.loaded) {
			const p = {};
			for (const line of ptext.split("\n")) {
				const f = line.trim().split(/\s+/);
				if (f.length >= 2 && f[1].startsWith("avg10="))
					p[f[0]] = f[1].slice(6);
			}
			if (p.some !== undefined)
				psi = "some " + p.some + "%  ·  full " + (p.full ?? "0.00") + "%";
		}

		// rows in the script's order; H heading, R sized row, T text row
		const rows = [];
		const kib = (a, k, pc) => rows.push({ k: "R", a: a, b: human(k), p: pc });

		rows.push({ k: "H", a: "RAM", b: human(total) });
		kib("Used", used, pct);
		kib("Anonymous", m("AnonPages"));
		kib("Cache", m("Buffers") + m("Cached") + m("SReclaimable"));
		kib("Available", avail);

		if (swapTotal > 0) {
			rows.push({ k: "H", a: "Swap", b: human(swapTotal) });
			kib("Used", swapUsed, percent(swapUsed, swapTotal));
			for (const r of swapRows)
				rows.push(r);
		} else {
			rows.push({ k: "H", a: "Swap", b: "none" });
		}

		rows.push({ k: "H", a: "System", b: "" });
		const limit = m("CommitLimit"), commit = m("Committed_AS");
		if (limit > 0)
			rows.push({ k: "R", a: "Committed", b: pair(commit, limit),
				p: Math.min(100, percent(commit, limit)) });
		if (psi !== "")
			rows.push({ k: "T", a: "Pressure", b: psi });
		// SUnreclaim, not Slab: the reclaimable half is already in Cache
		kib("Kernel", m("SUnreclaim") + m("PageTables") + m("KernelStack"));

		let labelChars = 0, valueChars = 0;
		for (const r of rows) {
			if (r.k === "H")
				continue;
			labelChars = Math.max(labelChars, r.a.length);
			if (r.k === "R")
				valueChars = Math.max(valueChars, r.b.length);
		}

		d = {
			pct: pct,
			usedTotal: pair(used, total),
			rows: rows,
			labelChars: labelChars,
			valueChars: valueChars
		};
	}

	Timer {
		interval: 2000
		running: true
		repeat: true
		triggeredOnStart: true
		onTriggered: view.sample()
	}

	// ---- view -------------------------------------------------------------

	// headline: percentage used, and used / total in the accent
	Item {
		width: parent.width
		implicitHeight: headPct.implicitHeight

		Label {
			id: headPct
			text: (view.d?.pct ?? 0) + "%"
			color: Theme.ramp(view.d?.pct ?? 0)
			font.pixelSize: Theme.headSize
			font.bold: true
		}
		Label {
			anchors.right: parent.right
			anchors.verticalCenter: headPct.verticalCenter
			text: view.d?.usedTotal ?? ""
			color: Theme.accent
			font.pixelSize: Theme.chipSize
			font.bold: true
		}
	}

	Meter {
		width: parent.width
		implicitHeight: 8
		value: view.d?.pct ?? 0
	}

	// RAM, Swap, System: a rule and a heading before each group, then dim
	// label / bold value rows; sized rows with a share get a meter
	Column {
		width: parent.width
		spacing: 3

		Repeater {
			model: view.rowCount

			Column {
				id: entry
				required property int index
				readonly property var r: view.d?.rows[index] ?? ({ k: "", a: "", b: "" })
				readonly property bool heading: r.k === "H"
				readonly property bool hasPct: r.p !== undefined

				width: parent.width

				// group heading: accent title, its total dim on the right
				Column {
					visible: entry.heading
					width: parent.width
					spacing: 10
					topPadding: entry.index > 0 ? 7 : 0
					bottomPadding: 3

					Rule { width: parent.width }
					Item {
						width: parent.width
						implicitHeight: title.implicitHeight
						Label {
							id: title
							text: entry.r.a
							color: Theme.accent
							font.bold: true
						}
						Label {
							anchors.right: parent.right
							text: entry.r.b
							color: Theme.dim
						}
					}
				}

				Row {
					visible: !entry.heading
					spacing: 16

					Label {
						width: view.labelW
						text: entry.r.a
						color: Theme.dim
					}

					// a sentence: zram compression, pressure pair
					Label {
						visible: entry.r.k === "T"
						text: entry.r.b
					}

					// a figure, right-aligned into its column, and its share
					Row {
						visible: entry.r.k === "R"
						spacing: 10

						Label {
							width: view.valueW
							horizontalAlignment: Text.AlignRight
							text: entry.r.b
							font.bold: true
						}
						Row {
							visible: entry.hasPct
							spacing: 8
							anchors.verticalCenter: parent.verticalCenter

							Meter {
								width: view.meterW
								anchors.verticalCenter: parent.verticalCenter
								value: entry.r.p ?? 0
							}
							Label {
								width: view.pctW
								horizontalAlignment: Text.AlignRight
								text: (entry.r.p ?? 0) + "%"
								color: Theme.ramp(entry.r.p ?? 0)
							}
						}
					}
				}
			}
		}
	}
}
