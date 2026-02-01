export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // ================= 配置区域 =================
    const GITHUB_USER = "0Sycamores";
    const GITHUB_REPO = "dotfiles";
    const BRANCH = "main";
    
    // 仓库主页 (跳转目标)
    const REPO_HOME_URL = `https://github.com/${GITHUB_USER}/${GITHUB_REPO}`;
    
    // Raw 文件基础地址
    const RAW_BASE_URL = `https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}`;

    // 定义仅有的几个“合法”脚本路径
    const ROUTES = {
      "/livecd":  "scripts/livecd.sh",
      "/livecd.sh":  "scripts/livecd.sh",
      "/setup": "scripts/arch-setup/setup.sh",
      "/setup.sh": "scripts/arch-setup/setup.sh",
    };
    // ===========================================

    // 1. 检查是否命中定义的脚本路径
    const scriptName = ROUTES[url.pathname];

    if (scriptName) {
      // 命中 -> 代理下载
      const targetUrl = `${RAW_BASE_URL}/${scriptName}`;
      return proxyRequest(targetUrl, request);
    }

    // 2. 通用代理逻辑: 检查路径是否以 http 开头 (例如 git clone https://arch.../https://github.com/...)
    // 去掉开头的 '/'，并保留查询参数
    const rawPath = url.pathname.slice(1) + url.search;

    if (rawPath.startsWith("http://") || rawPath.startsWith("https://")) {
        // 安全检查：只允许代理特定的仓库 (防止被滥用)
        const ALLOWED_PREFIXES = [
            `https://github.com/${GITHUB_USER}/${GITHUB_REPO}`,
            `https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}`
        ];

        const isAllowed = ALLOWED_PREFIXES.some(prefix => rawPath.startsWith(prefix));

        if (isAllowed) {
            return proxyRequest(rawPath, request);
        }
        
        return new Response("Forbidden: Access to this repository is not allowed via this proxy.", { status: 403 });
    }
    
    // 3. 所有其他情况 (根路径 /) -> 全部 302 跳转回 GitHub
    return Response.redirect(REPO_HOME_URL, 302);
  },
};

/**
 * 通用代理请求处理函数
 * @param {string} targetUrl
 * @param {Request} baseRequest
 */
async function proxyRequest(targetUrl, baseRequest) {
    try {
        const newHeaders = new Headers(baseRequest.headers);
        newHeaders.set("Host", new URL(targetUrl).host);
        
        // 简单的防盗链处理/伪装
        if (targetUrl.includes("github")) {
             newHeaders.set("Referer", "https://github.com/");
             newHeaders.set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36");
        }

        const newRequest = new Request(targetUrl, {
            method: baseRequest.method,
            headers: newHeaders,
            body: baseRequest.body,
            redirect: "follow"
        });

        const response = await fetch(newRequest);
        
        // 重建响应头，处理 CORS
        const newResponseHeaders = new Headers(response.headers);
        newResponseHeaders.set("Access-Control-Allow-Origin", "*");
        newResponseHeaders.set("Access-Control-Allow-Methods", "GET, POST, HEAD, OPTIONS");

        return new Response(response.body, {
            status: response.status,
            headers: newResponseHeaders
        });
    } catch (e) {
        return new Response("Proxy Error: " + e.message, { status: 500 });
    }
}