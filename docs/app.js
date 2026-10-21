(() => {
  "use strict";

  const CHECK_DEFS = [
    { id: "ip", title: "出口 IP / 归属", sub: "ipinfo.io 优先，Cloudflare trace 兜底" },
    { id: "region", title: "地区一致性", sub: "浏览器时区、语言与出口国家是否矛盾" },
    { id: "webrtc", title: "WebRTC 泄漏", sub: "STUN 候选地址与出口 IP 比对" },
    { id: "ipv6", title: "IPv6 暴露", sub: "是否能通过 IPv6 绕过代理直连" },
    { id: "dns", title: "DNS 泄漏（近似）", sub: "公共加密解析通道可达性" },
    { id: "fingerprint", title: "浏览器指纹展示", sub: "Canvas / WebGL / 设备信息（仅展示）" },
  ];

  const STATUS_TEXT = {
    ok: "通过",
    warn: "注意",
    fail: "失败",
    running: "检测中",
  };

  const COUNTRY_LANGS = {
    US: ["en"],
    GB: ["en"],
    AU: ["en"],
    CA: ["en"],
    JP: ["ja"],
    TW: ["zh-TW", "zh-Hant"],
    HK: ["zh-HK", "zh-Hant"],
    KR: ["ko"],
    DE: ["de"],
    FR: ["fr"],
    SG: ["en", "zh"],
  };

  const TZ_ALIASES = {
    "asia/calcutta": "asia/kolkata",
    "asia/saigon": "asia/ho_chi_minh",
    "europe/kiev": "europe/kyiv",
    "america/buenos_aires": "america/argentina/buenos_aires",
    utc: "etc/utc",
    gmt: "etc/gmt",
  };

  const PROXY_ORG_RE = /(vpn|proxy|hosting|cloud|server|data\s*center|datacenter|amazon|aws|google|microsoft|azure|oracle|digitalocean|ovh|hetzner|vultr|linode|akamai|cloudflare|leaseweb|m247|contabo|alibaba|tencent|choopa|psychz|colocrossing|mullvad|nord|express|surfshark)/i;

  const state = {
    running: false,
    completed: 0,
    results: new Map(),
    egress: null,
    ui: {},
  };

  let regionNames = null;
  try {
    regionNames = new Intl.DisplayNames(["zh-CN"], { type: "region" });
  } catch (_) {
    regionNames = null;
  }

  const els = {
    summary: document.getElementById("summary"),
    scoreRing: document.getElementById("score-ring"),
    scoreValue: document.getElementById("score-value"),
    verdict: document.getElementById("verdict"),
    verdictDetail: document.getElementById("verdict-detail"),
    progress: document.getElementById("progress"),
    progressBar: document.getElementById("progress-bar"),
    progressText: document.getElementById("progress-text"),
    rerun: document.getElementById("rerun"),
    fileNotice: document.getElementById("file-notice"),
    cardList: document.getElementById("card-list"),
    conclusion: document.getElementById("conclusion"),
    conclusionStatus: document.getElementById("conclusion-status"),
    conclusionStatusText: document.getElementById("conclusion-status-text"),
    conclusionVerdict: document.getElementById("conclusion-verdict"),
    conclusionFails: document.getElementById("conclusion-fails"),
  };

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function clipText(value, max = 160) {
    if (typeof value !== "string") return "";
    const text = value.trim();
    return text.length > max ? text.slice(0, max) + "…" : text;
  }

  function friendlyError(error) {
    if (!error) return "未知错误";
    if (error.name === "AbortError") return "请求超时";
    if (error.name === "TypeError") return "网络不可达或被 CORS 拦截";
    const message = error.message ? String(error.message) : String(error);
    return clipText(message, 120);
  }

  function countryName(code) {
    const value = typeof code === "string" ? code.trim().toUpperCase() : "";
    if (!value) return "未知";
    try {
      if (regionNames) return regionNames.of(value) || value;
    } catch (_) {
      return value;
    }
    return value;
  }

  function getBrowserTimeZone() {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone || "未知";
    } catch (_) {
      return "未知";
    }
  }

  function getBrowserLanguages() {
    const list = Array.isArray(navigator.languages) && navigator.languages.length
      ? Array.from(navigator.languages)
      : [navigator.language];
    return list.filter((lang) => typeof lang === "string" && lang.trim()).map((lang) => lang.trim());
  }

  function formatUtcOffset(minutes) {
    const sign = minutes >= 0 ? "+" : "-";
    const absolute = Math.abs(minutes);
    const hours = String(Math.floor(absolute / 60)).padStart(2, "0");
    const mins = String(absolute % 60).padStart(2, "0");
    return `UTC${sign}${hours}:${mins}`;
  }

  function normalizeTimeZone(zone) {
    const key = String(zone || "").trim().toLowerCase();
    return TZ_ALIASES[key] || key;
  }

  function sameTimeZone(a, b) {
    return normalizeTimeZone(a) === normalizeTimeZone(b);
  }

  function languageMatches(lang, allowed) {
    const value = String(lang || "").toLowerCase();
    return allowed.some((candidate) => {
      const normalized = candidate.toLowerCase();
      return value === normalized || value.startsWith(normalized + "-");
    });
  }

  function fetchWithTimeout(url, options = {}, timeout = 5000) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeout);
    return fetch(url, {
      ...options,
      mode: "cors",
      credentials: "omit",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      signal: controller.signal,
    }).finally(() => clearTimeout(timer));
  }

  async function fetchJSON(url, timeout = 5000) {
    const response = await fetchWithTimeout(url, { headers: { Accept: "application/json" } }, timeout);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.json();
  }

  async function fetchText(url, timeout = 5000) {
    const response = await fetchWithTimeout(url, { headers: { Accept: "text/plain" } }, timeout);
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return response.text();
  }

  function parseTrace(text) {
    const result = {};
    String(text || "").split("\n").forEach((line) => {
      const index = line.indexOf("=");
      if (index > 0) {
        result[line.slice(0, index).trim()] = line.slice(index + 1).trim();
      }
    });
    return result;
  }

  function isIPv4(addr) {
    const parts = String(addr || "").split(".");
    if (parts.length !== 4) return false;
    return parts.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255);
  }

  function isIPv6(addr) {
    const value = String(addr || "").trim().replace(/^\[|\]$/g, "").toLowerCase();
    if (!value.includes(":")) return false;
    if (/^::ffff:\d+\.\d+\.\d+\.\d+$/.test(value)) return true;
    return /^[0-9a-f:.]+$/.test(value) && value.split(":").length >= 3;
  }

  function isPrivateAddress(addr) {
    let value = String(addr || "").trim().replace(/^\[|\]$/g, "").toLowerCase();
    const mapped = value.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) value = mapped[1];

    if (isIPv4(value)) {
      const parts = value.split(".").map(Number);
      const [a, b, c] = parts;
      return (
        a === 0 ||
        a === 10 ||
        a === 127 ||
        (a === 169 && b === 254) ||
        (a === 172 && b >= 16 && b <= 31) ||
        (a === 192 && b === 168) ||
        (a === 100 && b >= 64 && b <= 127) ||
        (a === 192 && b === 0 && (c === 0 || c === 2)) ||
        (a === 198 && (b === 51 || b === 100)) ||
        (a === 203 && b === 0 && c === 113) ||
        a >= 224
      );
    }

    if (isIPv6(value)) {
      if (value === "::" || value === "::1") return true;
      if (/^fe[89ab]/.test(value)) return true;
      if (/^f[cd]/.test(value)) return true;
      if (/^ff/.test(value)) return true;
      if (value.startsWith("2001:db8")) return true;
    }

    return false;
  }

  function isFakeIP(addr) {
    if (!isIPv4(addr)) return false;
    const parts = String(addr).split(".").map(Number);
    return parts[0] === 198 && (parts[1] === 18 || parts[1] === 19);
  }

  function classifyAddress(addr) {
    const value = String(addr || "").trim().replace(/^\[|\]$/g, "");
    if (!value) return "invalid";
    if (value.toLowerCase().endsWith(".local")) return "mdns";
    if (isFakeIP(value)) return "fake";
    if (isPrivateAddress(value)) return "private";
    if (isIPv4(value) || isIPv6(value)) return "public";
    return "other";
  }

  function expandIPv6(addr) {
    const value = String(addr || "").trim().replace(/^\[|\]$/g, "").toLowerCase();
    if (!value.includes(":")) return value;
    const [head, tail] = value.split("::");
    const left = head ? head.split(":") : [];
    const right = tail ? tail.split(":") : [];
    if (value.includes("::")) {
      const missing = Math.max(0, 8 - left.length - right.length);
      return [...left, ...Array(missing).fill("0"), ...right]
        .map((group) => group.padStart(4, "0"))
        .join(":");
    }
    return left.map((group) => group.padStart(4, "0")).join(":");
  }

  function normalizeIP(addr) {
    let value = String(addr || "").trim().replace(/^\[|\]$/g, "").toLowerCase();
    const mapped = value.match(/^::ffff:(\d+\.\d+\.\d+\.\d+)$/);
    if (mapped) value = mapped[1];
    return value.includes(":") ? expandIPv6(value) : value;
  }

  function sameIP(a, b) {
    if (!a || !b) return false;
    return normalizeIP(a) === normalizeIP(b);
  }

  function orgLooksProxy(org) {
    return PROXY_ORG_RE.test(String(org || ""));
  }

  async function detectEgress() {
    const errors = [];

    try {
      const data = await fetchJSON("https://ipinfo.io/json");
      if (data && typeof data.ip === "string" && data.ip.trim()) {
        return {
          data: {
            ip: clipText(data.ip, 64),
            country: clipText(data.country, 8),
            city: clipText(data.city || data.region || "", 80),
            region: clipText(data.region || "", 80),
            org: clipText(data.org || "", 160),
            timezone: clipText(data.timezone || "", 80),
            source: "ipinfo.io",
          },
          fallback: false,
          errors,
        };
      }
      throw new Error("ipinfo.io 未返回 ip 字段");
    } catch (error) {
      errors.push(["ipinfo.io", friendlyError(error)]);
    }

    try {
      const trace = parseTrace(await fetchText("https://www.cloudflare.com/cdn-cgi/trace"));
      if (trace.ip) {
        return {
          data: {
            ip: clipText(trace.ip, 64),
            country: clipText(trace.loc || "", 8),
            city: "",
            region: "",
            org: "",
            timezone: "",
            source: "Cloudflare trace",
          },
          fallback: true,
          errors,
        };
      }
      throw new Error("trace 未返回 ip 字段");
    } catch (error) {
      errors.push(["Cloudflare trace", friendlyError(error)]);
    }

    return { data: null, fallback: false, errors };
  }

  async function checkIP(ipTask) {
    const egress = await ipTask;

    if (!egress.data) {
      return {
        status: "fail",
        summary: "无法获取出口 IP",
        rows: egress.errors.map(([source, message]) => ({ label: source, value: message })),
        notes: [
          "出口信息是地区一致性、WebRTC、IPv6 比对的基础；相关检查会降级为「无法比对」。",
          "请确认网络可用，或检查浏览器是否拦截了跨域请求。",
        ],
      };
    }

    state.egress = egress.data;
    const data = egress.data;
    const rows = [
      { label: "出口 IP", value: data.ip, mono: true },
      {
        label: "国家 / 地区",
        value: data.country ? `${countryName(data.country)}（${data.country}）` : "未提供",
      },
      {
        label: "城市 / 区域",
        value: data.city || data.region || "未提供",
      },
      { label: "ASN / 机构", value: data.org || "未提供" },
      { label: "时区", value: data.timezone || "未提供" },
      { label: "数据源", value: data.source },
    ];

    const notes = [
      "ASN / org 可用于判断住宅宽带与机房 IP；本页只展示，不替代桌面版的 ASN 属性审计。",
    ];

    if (egress.fallback) {
      const ipinfoError = egress.errors.find(([source]) => source === "ipinfo.io");
      notes.push(
        `ipinfo.io 不可用${ipinfoError ? `（${ipinfoError[1]}）` : ""}，已回退 Cloudflare trace；城市、ASN 与时区信息缺失。`
      );
    }
    if (isPrivateAddress(data.ip)) {
      notes.push("出口 IP 属于内网或保留地址，可能没有正确经由代理出口。");
    }

    return {
      status: egress.fallback ? "warn" : "ok",
      summary: egress.fallback
        ? `出口 IP ${data.ip}，已使用兜底数据源`
        : `出口 IP ${data.ip}，归属信息已获取`,
      rows,
      notes,
    };
  }

  async function checkRegion(ipTask) {
    const egress = await ipTask;
    const data = egress.data;
    const timeZone = getBrowserTimeZone();
    const offset = formatUtcOffset(-new Date().getTimezoneOffset());
    const languages = getBrowserLanguages();

    const rows = [
      { label: "浏览器时区", value: timeZone, mono: true },
      { label: "UTC 偏移", value: offset, mono: true },
      { label: "出口时区", value: data?.timezone || "未提供", mono: Boolean(data?.timezone) },
      { label: "浏览器语言", value: languages.length ? languages.join(", ") : "未提供" },
    ];

    if (!data) {
      return {
        status: "warn",
        summary: "缺少出口信息，无法比对",
        rows,
        notes: ["地区一致性依赖出口国家与时区；请先修复出口 IP 检测。"],
      };
    }

    const issues = [];
    const notes = [];
    let timeZoneState = "无法比对";

    if (data.timezone) {
      if (sameTimeZone(timeZone, data.timezone)) {
        timeZoneState = "一致";
      } else {
        timeZoneState = "不一致";
        issues.push(`时区与出口IP不符（浏览器 ${timeZone} ≠ 出口 ${data.timezone}）`);
        notes.push("时区不一致会形成明显的地理矛盾信号，建议将系统时区调整为出口时区。");
      }
    } else {
      notes.push("出口数据源未返回时区，时区一致性无法判定。");
    }
    rows.push({ label: "时区对照", value: timeZoneState });

    const country = data.country ? data.country.toUpperCase() : "";
    const allowed = country ? COUNTRY_LANGS[country] : null;
    let languageState = "无映射，跳过";

    if (allowed) {
      const matched = languages.some((lang) => languageMatches(lang, allowed));
      if (matched) {
        languageState = `匹配（${country} 常用 ${allowed.join(" / ")}）`;
      } else {
        languageState = `不匹配（${country} 常用 ${allowed.join(" / ")}）`;
        issues.push(
          `浏览器语言与出口国家不符（${country} 常用 ${allowed.join("/")}，当前 ${languages[0] || "未知"}）`
        );
        notes.push("navigator.language 会暴露系统语言；建议与出口国家常用语言保持一致。");
      }
    } else if (country) {
      notes.push(`出口国家 ${country} 不在主要语言映射表中，语言项仅展示不判定。`);
    }
    rows.push({ label: "语言对照", value: languageState });

    notes.push("本项只读取浏览器暴露的时区与语言，不代表系统级全部区域设置。");

    if (issues.length) {
      return {
        status: "warn",
        summary: `发现 ${issues.length} 处地区信号不一致`,
        rows,
        notes,
      };
    }

    if (timeZoneState === "一致" && (!allowed || languageState.startsWith("匹配"))) {
      return {
        status: "ok",
        summary: allowed ? "时区与语言均与出口一致" : "时区一致；语言项未映射，仅展示",
        rows,
        notes,
      };
    }

    return {
      status: "warn",
      summary: "部分地区信息不足，无法完整比对",
      rows,
      notes,
    };
  }

  function parseICECandidate(line) {
    if (typeof line !== "string") return null;
    const parts = line.trim().split(/\s+/);
    if (parts.length < 8) return null;
    const address = parts[4];
    const port = parts[5];
    const typeIndex = parts.indexOf("typ");
    const type = typeIndex >= 0 ? (parts[typeIndex + 1] || "").toLowerCase() : "";
    if (!address) return null;
    return { address, port, type };
  }

  async function collectWebRTC() {
    if (typeof window.RTCPeerConnection !== "function") {
      return { supported: false, candidates: [], error: "浏览器不支持 RTCPeerConnection" };
    }

    let peer = null;
    try {
      peer = new RTCPeerConnection({
        iceServers: [
          { urls: "stun:stun.l.google.com:19302" },
          { urls: "stun:stun.cloudflare.com:3478" },
        ],
      });
    } catch (error) {
      return { supported: false, candidates: [], error: friendlyError(error) };
    }

    const candidates = [];
    let settled = false;
    let timer = null;

    const gathered = new Promise((resolve) => {
      const finish = () => {
        if (settled) return;
        settled = true;
        if (timer) clearTimeout(timer);
        resolve();
      };

      peer.addEventListener("icecandidate", (event) => {
        if (event.candidate && event.candidate.candidate) {
          candidates.push(event.candidate.candidate);
        } else {
          finish();
        }
      });

      peer.addEventListener("icegatheringstatechange", () => {
        if (peer.iceGatheringState === "complete") finish();
      });

      timer = setTimeout(finish, 4500);
    });

    try {
      peer.createDataChannel("probe");
      const offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      await gathered;
    } catch (error) {
      try {
        peer.close();
      } catch (_) {
        /* noop */
      }
      return { supported: true, candidates, error: friendlyError(error) };
    }

    try {
      peer.close();
    } catch (_) {
      /* noop */
    }

    return { supported: true, candidates, error: null };
  }

  async function checkWebRTC(ipTask, webrtcTask) {
    const egress = (await ipTask).data;
    const probe = await webrtcTask;

    if (!probe.supported) {
      return {
        status: "warn",
        summary: "浏览器不支持或阻止 WebRTC，无法判定",
        rows: [{ label: "RTCPeerConnection", value: probe.error || "不可用" }],
        notes: ["无结果不等于没有泄漏；如果你的代理不接管 UDP，仍建议用桌面版复核。"],
      };
    }

    const entriesByAddress = new Map();

    for (const raw of probe.candidates) {
      const parsed = parseICECandidate(raw);
      if (!parsed) continue;
      const kind = classifyAddress(parsed.address);
      if (kind === "invalid" || kind === "other") continue;
      const key = parsed.address.toLowerCase();
      if (!entriesByAddress.has(key)) {
        entriesByAddress.set(key, {
          address: parsed.address,
          kinds: new Set(),
          types: new Set(),
        });
      }
      const entry = entriesByAddress.get(key);
      entry.kinds.add(kind);
      if (parsed.type) entry.types.add(parsed.type);
    }

    const entries = Array.from(entriesByAddress.values());
    const publicEntries = entries.filter((entry) => entry.kinds.has("public"));
    const mdnsCount = entries.filter((entry) => entry.kinds.has("mdns")).length;
    const privateCount = entries.filter((entry) => entry.kinds.has("private")).length;
    const fakeCount = entries.filter((entry) => entry.kinds.has("fake")).length;

    const rows = [
      { label: "出口 IP", value: egress?.ip || "未获取", mono: Boolean(egress) },
      { label: "候选总数", value: String(probe.candidates.length) },
      {
        label: "公网候选",
        value: publicEntries.length
          ? publicEntries
              .map((entry) => `${entry.address}（${Array.from(entry.types).join("/") || "类型未知"}）`)
              .join("\n")
          : "无",
        mono: publicEntries.length > 0,
      },
      { label: "内网候选", value: privateCount ? `${privateCount} 个` : "无" },
      {
        label: "mDNS 混淆",
        value: mdnsCount ? `已启用（${mdnsCount} 个 .local）` : "未出现",
      },
    ];

    if (fakeCount) {
      rows.push({ label: "fake-IP", value: `${fakeCount} 个（不判定为泄漏）` });
    }
    if (probe.error) {
      rows.push({ label: "探测状态", value: probe.error });
    }

    const notes = [];

    if (mdnsCount) {
      notes.push("候选地址被 mDNS 混淆为 .local，这是浏览器隐私保护行为，视为安全。");
    }
    if (fakeCount) {
      notes.push("检测到 fake-IP 段（198.18.0.0/15），常见于 Clash TUN 的 DNS 接管，不视为泄漏。");
    }

    if (!egress && publicEntries.length) {
      return {
        status: "warn",
        summary: "检测到公网候选，但缺少出口 IP 无法比对",
        rows,
        notes,
      };
    }

    const extra = publicEntries.filter((entry) => !egress || !sameIP(entry.address, egress.ip));

    if (extra.length) {
      notes.push("额外公网 IP 与出口不一致，说明 UDP/STUN 可能绕过代理。请确认 TUN 接管 UDP，或更换支持 UDP 的节点。");
      return {
        status: "fail",
        summary: "WebRTC 暴露额外公网 IP",
        rows,
        notes,
      };
    }

    if (publicEntries.length) {
      notes.push("所有公网候选都与出口 IP 一致，未发现额外地址。");
      return {
        status: "ok",
        summary: "仅出口 IP 可见",
        rows,
        notes,
      };
    }

    if (mdnsCount) {
      notes.push("未收集到公网候选；mDNS 已拦截本地地址暴露。");
      return {
        status: "ok",
        summary: "候选被 mDNS 混淆，未暴露公网 IP",
        rows,
        notes,
      };
    }

    if (!probe.candidates.length) {
      notes.push("浏览器可能禁用了 WebRTC、未放行 STUN，或网络屏蔽 UDP。该结果不能证明安全。");
      return {
        status: "warn",
        summary: "无法判定（可能被浏览器策略阻止）",
        rows,
        notes,
      };
    }

    notes.push("仅收集到内网或本地候选，未发现公网地址。");
    return {
      status: "ok",
      summary: "未发现公网 WebRTC 候选",
      rows,
      notes,
    };
  }

  async function probeIPv6() {
    try {
      const data = await fetchJSON("https://api6.ipify.org?format=json", 3000);
      if (!data || typeof data.ip !== "string" || !data.ip.includes(":")) {
        return { ok: false, error: "API 未返回 IPv6 地址" };
      }
      return { ok: true, ip: clipText(data.ip, 64) };
    } catch (error) {
      return { ok: false, error: friendlyError(error) };
    }
  }

  async function checkIPv6(ipTask, ipv6Task) {
    const egress = (await ipTask).data;
    const probe = await ipv6Task;

    if (!probe.ok) {
      return {
        status: "ok",
        summary: "IPv6 不可达或已被接管",
        rows: [
          { label: "IPv6 探测", value: "未取得地址" },
          { label: "探测结果", value: probe.error || "无 IPv6 连通性" },
          { label: "出口 IP", value: egress?.ip || "未获取", mono: Boolean(egress) },
        ],
        notes: [
          "未取到 IPv6 地址，可能是网络无 IPv6、代理拦截或浏览器限制；这不等于系统 IPv6 一定已关闭。",
        ],
      };
    }

    const ipv6 = probe.ip;
    const rows = [
      { label: "IPv6 地址", value: ipv6, mono: true },
      { label: "出口 IP", value: egress?.ip || "未获取", mono: Boolean(egress) },
    ];

    if (egress && sameIP(ipv6, egress.ip)) {
      return {
        status: "ok",
        summary: "出口即 IPv6，未发现独立旁路",
        rows,
        notes: ["当前出口本身就是 IPv6，未检测到额外的 IPv4/IPv6 双栈旁路。"],
      };
    }

    let info = null;
    let lookupError = "";
    try {
      info = await fetchJSON(`https://ipinfo.io/${encodeURIComponent(ipv6)}/json`);
    } catch (error) {
      lookupError = friendlyError(error);
    }

    if (info) {
      rows.push({ label: "IPv6 国家", value: clipText(info.country || "", 8) || "未提供" });
      rows.push({ label: "IPv6 ASN / 机构", value: clipText(info.org || "", 160) || "未提供" });
    } else {
      rows.push({ label: "IPv6 归属查询", value: lookupError || "不可用" });
    }

    const org = info && typeof info.org === "string" ? info.org : "";
    const proxyLike = orgLooksProxy(org);
    const countryMismatch =
      info &&
      info.country &&
      egress &&
      egress.country &&
      String(info.country).toUpperCase() !== String(egress.country).toUpperCase();

    const notes = [
      "IPv6 能直连不等于一定泄漏：若 TUN/代理已接管 IPv6，出口应为代理地址。本页无法读取系统路由表。",
    ];

    if (countryMismatch) {
      notes.push("IPv6 归属国家与 IPv4 出口国家不一致，疑似 IPv6 未走代理。");
      return {
        status: "fail",
        summary: "IPv6 出口国家与 IPv4 不一致",
        rows,
        notes,
      };
    }

    if (!egress) {
      notes.push("缺少 IPv4 出口信息，无法判断 IPv6 是否与代理一致，建议用桌面版复核。");
      return {
        status: "warn",
        summary: "IPv6 可直连，但缺少出口对照",
        rows,
        notes,
      };
    }

    if (proxyLike) {
      notes.push("IPv6 归属机构看似机房或代理，可能已由代理接管；仍建议用桌面版复核。");
      return {
        status: "warn",
        summary: "IPv6 可直连，归属看似代理 / 机房",
        rows,
        notes,
      };
    }

    if (org) {
      notes.push("IPv6 归属不似代理或机房，若代理未接管 IPv6 将暴露真实地址。建议关闭系统 IPv6 或启用 IPv6 接管。");
      return {
        status: "fail",
        summary: "IPv6 可直连，疑似暴露真实地址",
        rows,
        notes,
      };
    }

    notes.push("未能获取 IPv6 归属信息，无法区分代理出口与真实地址；建议用桌面版复核。");
    return {
      status: "warn",
      summary: "IPv6 可直连，但归属未知",
      rows,
      notes,
    };
  }

  async function checkDNS() {
    const [cloudflare, google] = await Promise.allSettled([
      fetchText("https://1.1.1.1/cdn-cgi/trace"),
      fetchJSON("https://dns.google/resolve?name=claude.ai&type=A"),
    ]);

    const rows = [];
    let cloudflareOk = false;
    let googleOk = false;

    if (cloudflare.status === "fulfilled") {
      cloudflareOk = true;
      const trace = parseTrace(cloudflare.value);
      rows.push({
        label: "1.1.1.1 trace",
        value: `可达 · 节点 ${trace.colo || "未知"} · loc ${trace.loc || "未知"}`,
      });
    } else {
      rows.push({ label: "1.1.1.1 trace", value: `不可达 · ${friendlyError(cloudflare.reason)}` });
    }

    if (google.status === "fulfilled") {
      googleOk = true;
      const answers = Array.isArray(google.value.Answer)
        ? google.value.Answer.filter((answer) => answer && answer.type === 1)
            .map((answer) => answer.data)
            .filter(Boolean)
        : [];
      rows.push({
        label: "Google DoH · claude.ai",
        value: answers.length ? answers.slice(0, 4).join("\n") : "可达（无 A 记录）",
        mono: answers.length > 0,
      });
    } else {
      rows.push({ label: "Google DoH · claude.ai", value: `不可达 · ${friendlyError(google.reason)}` });
    }

    rows.push({
      label: "判定",
      value: "仅近似：证明公共加密解析可达，不证明系统 DNS 未泄漏",
    });

    const notes = [
      "浏览器无法读取系统 DNS 配置，也无法知道域名最终由哪个解析器应答；本项不是 DNS 泄漏结论。",
      "要确认系统 DNS 是否被代理接管（Fake-IP / DNS 隧道），请使用桌面版的 14 项审计。",
    ];

    if (cloudflareOk && googleOk) {
      return { status: "ok", summary: "公共加密解析通道均可达", rows, notes };
    }
    if (cloudflareOk || googleOk) {
      return { status: "warn", summary: "部分公共解析通道不可达", rows, notes };
    }
    return { status: "warn", summary: "公共解析通道不可达，无法判定", rows, notes };
  }

  function fnv1a(text) {
    let hash = 0x811c9dc5;
    for (let index = 0; index < text.length; index += 1) {
      hash ^= text.charCodeAt(index);
      hash = Math.imul(hash, 0x01000193);
    }
    return (hash >>> 0).toString(16).padStart(8, "0");
  }

  function canvasFingerprint() {
    try {
      const canvas = document.createElement("canvas");
      canvas.width = 280;
      canvas.height = 60;
      const context = canvas.getContext("2d");
      if (!context) return "不可用";
      context.fillStyle = "#12141D";
      context.fillRect(0, 0, 280, 60);
      context.textBaseline = "alphabetic";
      context.fillStyle = "#7C5CFC";
      context.font = '16px "Helvetica Neue", Arial, sans-serif';
      context.fillText("Claude 环境检测 · 2026", 8, 24);
      context.fillStyle = "rgba(34, 197, 94, 0.8)";
      context.font = '12px "PingFang SC", "Microsoft YaHei", sans-serif';
      context.fillText("Canvas fingerprint / 指纹一致性", 8, 44);
      return `0x${fnv1a(canvas.toDataURL())}`;
    } catch (_) {
      return "不可用";
    }
  }

  function webglFingerprint() {
    try {
      const canvas = document.createElement("canvas");
      const context = canvas.getContext("webgl") || canvas.getContext("experimental-webgl");
      if (!context) return { vendor: "不可用", renderer: "不可用" };
      const extension = context.getExtension("WEBGL_debug_renderer_info");
      if (!extension) return { vendor: "UNMASKED 不可用", renderer: "UNMASKED 不可用" };
      return {
        vendor: clipText(String(context.getParameter(extension.UNMASKED_VENDOR_WEBGL) || "未知"), 160),
        renderer: clipText(String(context.getParameter(extension.UNMASKED_RENDERER_WEBGL) || "未知"), 160),
      };
    } catch (_) {
      return { vendor: "不可用", renderer: "不可用" };
    }
  }

  async function checkFingerprint() {
    const webgl = webglFingerprint();
    const rows = [
      { label: "Canvas 哈希", value: canvasFingerprint(), mono: true },
      { label: "WebGL 厂商", value: webgl.vendor },
      { label: "WebGL 渲染器", value: webgl.renderer },
      {
        label: "屏幕",
        value: `${screen.width} × ${screen.height} · DPR ${window.devicePixelRatio || 1}`,
      },
      { label: "色彩深度", value: `${screen.colorDepth} bit` },
      { label: "platform", value: navigator.platform || "未提供" },
      {
        label: "逻辑核心",
        value: navigator.hardwareConcurrency ? String(navigator.hardwareConcurrency) : "未提供",
      },
      {
        label: "设备内存",
        value: navigator.deviceMemory ? `≥ ${navigator.deviceMemory} GB` : "未提供（浏览器限制）",
      },
    ];

    return {
      status: "ok",
      summary: "已读取浏览器公开指纹，仅作一致性参考",
      rows,
      notes: [
        "Canvas / WebGL 显示为中性信息：桌面版 Claude 也可读取这些值，环境一致性比随机化更重要。",
        "这些值只在本页内存中展示，不发送、不存储；不建议为了反指纹而随机化 Canvas/WebGL，跨会话漂移反而更像异常设备。",
      ],
    };
  }

  function createCard(def, index) {
    const card = el("article", "card");
    card.id = `card-${def.id}`;
    card.dataset.state = "running";

    const head = el("header", "card-head");
    const indexNode = el("div", "card-index", String(index + 1).padStart(2, "0"));
    indexNode.setAttribute("aria-hidden", "true");

    const titleWrap = el("div", "card-title-wrap");
    titleWrap.append(el("h3", "card-title", def.title), el("p", "card-sub", def.sub));

    const status = el("span", "status");
    status.dataset.status = "running";
    const dot = el("span", "status-dot");
    dot.setAttribute("aria-hidden", "true");
    const statusText = el("span", "status-text", STATUS_TEXT.running);
    status.append(dot, statusText);

    head.append(indexNode, titleWrap, status);

    const body = el("div", "card-body");
    body.append(createSkeleton());
    card.append(head, body);

    return { card, status, statusText, body };
  }

  function createSkeleton() {
    const skeleton = el("div", "skeleton");
    skeleton.append(
      el("div", "sk-line sk-line-lg"),
      el("div", "sk-line"),
      el("div", "sk-line sk-line-sm")
    );
    return skeleton;
  }

  function renderResult(id, result) {
    const ui = state.ui[id];
    if (!ui) return;

    const status = result.status || "warn";
    ui.card.dataset.state = status;
    ui.status.dataset.status = status;
    ui.statusText.textContent = STATUS_TEXT[status] || "未知";

    const body = ui.body;
    body.replaceChildren();

    if (result.summary) {
      body.append(el("p", "card-summary", result.summary));
    }

    if (Array.isArray(result.rows) && result.rows.length) {
      const rows = el("div", "rows");
      for (const row of result.rows) {
        if (!row) continue;
        const rowNode = el("div", "row");
        rowNode.append(el("span", "row-label", row.label || ""));
        rowNode.append(
          el("span", "row-value" + (row.mono ? " is-mono" : ""), row.value == null ? "—" : String(row.value))
        );
        rows.append(rowNode);
      }
      body.append(rows);
    }

    if (Array.isArray(result.notes)) {
      for (const note of result.notes) {
        if (note) body.append(el("p", "note", note));
      }
    }
  }

  function updateProgress() {
    const total = CHECK_DEFS.length;
    const done = Math.min(state.completed, total);
    els.progressBar.style.width = `${(done / total) * 100}%`;
    els.progress.setAttribute("aria-valuenow", String(done));
    els.progressText.textContent = `${done} / ${total} 项完成`;
  }

  function updateLiveScore() {
    if (!state.completed) {
      els.scoreValue.textContent = "—";
      return;
    }
    const results = Array.from(state.results.values());
    const fails = results.filter((result) => result.status === "fail").length;
    const warns = results.filter((result) => result.status === "warn").length;
    const score = Math.max(0, 100 - fails * 25 - warns * 6);
    els.scoreValue.textContent = String(score);
    els.scoreRing.style.setProperty("--score", String(score));
  }

  async function runCheck(id, task) {
    const ui = state.ui[id];
    if (ui) {
      ui.card.dataset.state = "running";
      ui.status.dataset.status = "running";
      ui.statusText.textContent = STATUS_TEXT.running;
      ui.body.replaceChildren(createSkeleton());
    }

    let result;
    try {
      result = await task();
      if (!result || !result.status) throw new Error("检测未返回结果");
    } catch (error) {
      result = {
        status: "fail",
        summary: "检测执行失败",
        notes: [`${friendlyError(error)}。该项已降级，不影响其他检测项。`],
      };
    }

    state.results.set(id, result);
    renderResult(id, result);
    state.completed += 1;
    updateProgress();
    updateLiveScore();
  }

  function resetCards() {
    for (const def of CHECK_DEFS) {
      const ui = state.ui[def.id];
      if (!ui) continue;
      ui.card.dataset.state = "running";
      ui.status.dataset.status = "running";
      ui.statusText.textContent = STATUS_TEXT.running;
      ui.body.replaceChildren(createSkeleton());
    }
  }

  function resetConclusion() {
    els.conclusion.dataset.state = "running";
    els.conclusionStatus.dataset.status = "running";
    els.conclusionStatusText.textContent = "等待中";
    els.conclusionVerdict.textContent = "正在完成检测…";
    els.conclusionFails.replaceChildren();
  }

  function appendResultList(container, title, items, isWarn) {
    if (!items.length) return;
    container.append(el("p", "conclusion-list-title", title));
    const list = el("ul", "result-list" + (isWarn ? " is-warn" : ""));
    for (const item of items) {
      const row = el("li");
      const bullet = el("span", "result-bullet", isWarn ? "!" : "×");
      bullet.setAttribute("aria-hidden", "true");
      row.append(bullet);
      row.append(el("span", "", `${item.title}：${item.summary}`));
      list.append(row);
    }
    container.append(list);
  }

  function finalize() {
    if (state.completed < CHECK_DEFS.length) return;

    const fails = [];
    const warns = [];

    for (const def of CHECK_DEFS) {
      const result = state.results.get(def.id);
      if (!result) continue;
      const item = { title: def.title, summary: result.summary || STATUS_TEXT[result.status] || "" };
      if (result.status === "fail") fails.push(item);
      if (result.status === "warn") warns.push(item);
    }

    const score = Math.max(0, 100 - fails.length * 25 - warns.length * 6);
    const status = fails.length ? "fail" : warns.length ? "warn" : "ok";
    const verdict = fails.length ? `高风险：${fails.length} 项失败` : "环境基本合规";
    const detail = fails.length
      ? warns.length
        ? `建议先处理失败项再使用 Claude；另有 ${warns.length} 项需要留意。`
        : "建议先处理失败项再使用 Claude。"
      : warns.length
        ? `未发现失败项；${warns.length} 项需要留意。`
        : "6 项浏览器侧检测全部通过，未发现明显泄漏信号。";

    els.scoreValue.textContent = String(score);
    els.scoreRing.style.setProperty("--score", String(score));
    els.scoreRing.dataset.state = status;
    els.summary.dataset.state = status;
    els.verdict.textContent = verdict;
    els.verdictDetail.textContent = detail;
    els.progressBar.style.width = "100%";
    els.progress.setAttribute("aria-valuenow", String(CHECK_DEFS.length));
    els.progressText.textContent = `${CHECK_DEFS.length} / ${CHECK_DEFS.length} 项完成`;

    els.conclusion.dataset.state = status;
    els.conclusionStatus.dataset.status = status;
    els.conclusionStatusText.textContent = STATUS_TEXT[status];
    els.conclusionVerdict.textContent =
      status === "fail"
        ? `高风险：${fails.length} 项失败`
        : warns.length
          ? `环境基本合规，有 ${warns.length} 项需要留意`
          : "环境基本合规";

    els.conclusionFails.replaceChildren();
    appendResultList(els.conclusionFails, "失败项", fails, false);
    appendResultList(els.conclusionFails, "需要留意", warns, true);
    if (!fails.length && !warns.length) {
      els.conclusionFails.append(el("p", "all-clear", "6 项检测全部通过，未发现失败项。"));
    }
  }

  async function start() {
    if (state.running) return;

    state.running = true;
    state.completed = 0;
    state.results.clear();
    state.egress = null;

    els.rerun.disabled = true;
    els.rerun.classList.add("is-running");
    els.rerun.setAttribute("aria-busy", "true");
    els.summary.dataset.state = "running";
    els.scoreRing.dataset.state = "running";
    els.scoreRing.style.setProperty("--score", "0");
    els.scoreValue.textContent = "—";
    els.verdict.textContent = "正在检测…";
    els.verdictDetail.textContent = "正在采集浏览器侧信号，通常需要 5–10 秒。";
    els.progressBar.style.width = "0%";
    els.progress.setAttribute("aria-valuenow", "0");
    els.progressText.textContent = `0 / ${CHECK_DEFS.length} 项完成`;

    resetCards();
    resetConclusion();

    const ipTask = detectEgress();
    const webrtcTask = collectWebRTC();
    const ipv6Task = probeIPv6();

    try {
      await Promise.all([
        runCheck("ip", () => checkIP(ipTask)),
        runCheck("region", () => checkRegion(ipTask)),
        runCheck("webrtc", () => checkWebRTC(ipTask, webrtcTask)),
        runCheck("ipv6", () => checkIPv6(ipTask, ipv6Task)),
        runCheck("dns", checkDNS),
        runCheck("fingerprint", checkFingerprint),
      ]);
      finalize();
    } finally {
      state.running = false;
      els.rerun.disabled = false;
      els.rerun.classList.remove("is-running");
      els.rerun.removeAttribute("aria-busy");
    }
  }

  function init() {
    CHECK_DEFS.forEach((def, index) => {
      const ui = createCard(def, index);
      state.ui[def.id] = ui;
      els.cardList.append(ui.card);
    });

    els.rerun.addEventListener("click", () => {
      start();
    });

    if (window.location.protocol === "file:") {
      els.fileNotice.hidden = false;
      els.fileNotice.textContent =
        "当前通过 file:// 打开，浏览器会拦截跨域请求，检测结果不具参考性。请使用本地 HTTP 服务或 GitHub Pages 访问。";
    }

    start();
  }

  init();
})();
