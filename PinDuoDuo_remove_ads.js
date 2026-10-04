// 拼多多去广告 - homepage/hub 接口响应处理
// 由 Loon 插件 PinDuoDuo_remove_ads.lpx 转换而来，对应原插件两条 Rewrite：
//   1. response-body-json-del result.search_bar_hot_query result.dy_module.irregular_banner_dy
//   2. response-body-json-jq '.result.bottom_tabs? |= map(select(.link | IN("index.html", "chat_list.html", "personal.html"))) | .result.buffer_bottom_tabs? |= map(select(.link | IN("index.html", "chat_list.html", "personal.html")))'
// Surge 用法: type=http-response, requires-body=true
try {
  const obj = JSON.parse($response.body);
  const result = obj.result || {};

  // 1. 删除搜索框热词、异形 banner
  delete result.search_bar_hot_query;
  if (result.dy_module) delete result.dy_module.irregular_banner_dy;

  // 2. 底栏只保留 首页 / 聊天 / 个人（去掉多多视频、会场入口等）
  const keep = ["index.html", "chat_list.html", "personal.html"];
  ["bottom_tabs", "buffer_bottom_tabs"].forEach((k) => {
    if (Array.isArray(result[k])) {
      result[k] = result[k].filter((item) => item && keep.indexOf(item.link) !== -1);
    }
  });

  $done({ body: JSON.stringify(obj) });
} catch (e) {
  $done({});
}
