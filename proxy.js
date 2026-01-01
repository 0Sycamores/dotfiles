export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    
    // ================= 配置区域 =================
    const GITHUB_USER = "0Sycamores";
    const GITHUB_REPO = "sycamore-arch";
    const BRANCH = "main";
    
    // 仓库主页 (跳转目标)
    const REPO_HOME_URL = `https://github.com/${GITHUB_USER}/${GITHUB_REPO}`;
    
    // Raw 文件基础地址
    const RAW_BASE_URL = `https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}`;

    // 定义仅有的几个“合法”脚本路径
    const ROUTES = {
      "/livecd":  "livecd.sh",
      "/livecd.sh":  "livecd.sh",
      "/install": "install.sh",
      "/install.sh": "install.sh",
    };
    // ===========================================

    // 1. 检查是否命中定义的脚本路径
    const scriptName = ROUTES[url.pathname];

    if (scriptName) {
      // 命中 -> 代理下载
      const targetUrl = `${RAW_BASE_URL}/${scriptName}`;
      try {
        const response = await fetch(targetUrl);
        if (!response.ok) return new Response("Script retrieval failed", { status: response.status });

        return new Response(response.body, {
          status: 200,
          headers: {
            "Content-Type": "text/plain; charset=utf-8",
            "Cache-Control": "no-cache"
          },
        });
      } catch (e) {
        return new Response("Proxy Error", { status: 500 });
      }
    }

    // 2. 所有其他情况 (根路径 /，或者瞎写的路径 /abc) -> 全部 302 跳转回 GitHub
    return Response.redirect(REPO_HOME_URL, 302);
  },
};