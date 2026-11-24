# vps-traffic-guard

给自建代理的 VPS 加一道流量保险。

- **`check` 体检**：检查 Xray / sing-box 的 REALITY 回落目标（`target` / `dest`）是否指向 Cloudflare 等 CDN。很多流量被偷的情况就是这个原因。
- **每日额度**：把套餐流量按天发放，当天额度内满速；用完就限速，次日 0 点自动恢复。就算被偷，每天最多损失当天额度，加上限速状态下能跑的量（约一天的日均额度），不会几天就把整月流量烧光。
- **关端口（可选）**：安装时多问一句，要不要从外网关掉对公网开着、又用不到的端口（比如没设密码就对外开放的 Redis、MySQL）。默认不关；选“不关”就只装限流。

只有一个 bash 脚本，不联网上报任何数据。

## 一键安装

用 root 登录 VPS，粘贴这一行，然后按提示填写套餐流量、重置日和面板上的已用量：

```bash
bash <(curl -fsSL https://laosan186.github.io/vps-guard/i)
```

最后会问一句要不要顺便关掉用不到的端口，直接回车就是不关（见下文“关闭用不到的端口”）。

- 这条命令运行的是仓库里的 [`i`](i)，四十行左右：把主脚本下载到 `/usr/local/bin/vps-traffic-guard`，检查下载完整（不完整就停下，不覆盖已装的版本），再运行安装。可以先打开看看再跑。
- 以后更新到新版：再运行一次同一条命令，配置和计数会保留。不想回答问题就在末尾加 ` --yes`。
- `github.io` 打不开时，改用 GitHub 原始地址：先下载到当前目录，再安装（安装时确认了才会复制到 `/usr/local/bin`）：

```bash
curl -fsSLO https://raw.githubusercontent.com/Laosan186/vps-guard/main/vps-traffic-guard.sh && bash vps-traffic-guard.sh install
```

装完运行 `vps-traffic-guard check`，看看 REALITY 回落目标是否有问题。

## 为什么 REALITY 会被偷流量

REALITY 收到鉴权失败的连接时，会把它原样转发给 `target` 网站。Xray 官方文档对此有警告：`target` 如果用了 CDN（比如 Cloudflare），你的服务器就相当于它的端口转发，被扫描到后可能被人偷跑流量。

用 AI 或一键脚本部署的新手，常把 `target` 填成某个套了 Cloudflare 的域名。别人把自己的域名解析到你的 VPS IP 上，就能借你的 VPS 访问 Cloudflare 上的任何站点，流量全记在你头上。

所以要先治根：**运行 `check`，发现指向 CDN 就换掉 `target`**。每日额度只是兜底。

## 每日额度怎么算

```
今日额度 = (套餐 × 触发线 − 本期已用) ÷ 账期剩余天数（含今天）
```

- 每天 0 点重算一次。没用完的额度自动留给后面几天，不会浪费。
- 当天用完后开始限速。限速速率按“限速状态下满速跑一整天，计费流量也不超过日均额度”自动计算；越接近套餐上限，速率压得越低，按“满速跑到账期结束也不超过套餐 98%”来封顶。这是按本机计数估算的，不是硬保证：只限出口方向，不限速端口不受控，速率最低保留 64 kbit/s。
- 本期用到触发线（默认 90%）后，剩下的天数都处于限速状态。

**例子：套餐 1000G、双向计费、30 天账期**

| | 计费流量 | 约合实际代理用量 |
|---|---|---|
| 触发线 90% | 900 GB | 约 450 GB |
| 每日额度（从月初开始） | 30 GB | 约 15 GB |
| 超额后自动限速 | 约 1.39 Mbps | 能聊天、看网页，看视频会卡 |

代理节点上每个字节都要进出 VPS 各一次，双向计费时 1 GB 代理流量约记 2 GB。

## 安装

需要：KVM 等能改网卡队列的 VPS、systemd、root 权限，以及 bash、iproute2（ip、tc）、GNU date、awk。Debian / Ubuntu 一般自带；RHEL / Rocky / Alma 8 以上的最小化安装可能没有 tc，先执行 `dnf install -y iproute-tc`。

一键安装见上文。想先看看再装，也可以分步：

```bash
curl -fsSLO https://raw.githubusercontent.com/Laosan186/vps-guard/main/vps-traffic-guard.sh
less vps-traffic-guard.sh             # 可选：看看脚本做了什么
bash vps-traffic-guard.sh check       # 先体检，不需要安装
bash vps-traffic-guard.sh selftest    # 可选：在本机自检（会临时限速约 15 秒）
bash vps-traffic-guard.sh install     # 再安装
```

`selftest` 会检查环境、计算逻辑、systemd 单元、SSH 端口识别，并在本机真实限速约 15 秒、测一次速，确认限速生效、SSH 不受影响、撤销后恢复原样，最后输出一份报告。测速时会向 speed.cloudflare.com 上传约 10 MB 随机数据；不想测速可加 `--no-speed`。

安装时会问你几个问题。以下内容都在商家面板里能看到：

- 套餐每月流量（GB）
- 每月几号重置流量
- 计费方式：`both` 双向（进+出）、`out` 仅出站、`in` 仅入站、`max` 进出取较大值
- 本期面板上已经用了多少 GB（**月中安装时一定要填**，否则今日额度会偏大）

SSH 端口永不限速。端口会从 sshd 配置、ssh.socket、正在监听的端口、正在使用中的 SSH 连接里自动识别；正在使用中的 SSH 连接端口（包括你当前这个会话）会自动加入。识别依赖 `ss` 命令，安装前请确认摘要里的“永不限速端口”包含你的 SSH 端口。

不想交互时（建议显式写上 SSH 端口）：

```bash
bash vps-traffic-guard.sh install --quota 1000 --reset-day 5 --mode both --used 123 --exempt-ports "22" --yes
```

非交互安装默认不碰防火墙。加 `--close-ports` 会顺便关端口，但没人在旁边确认，所以要在 3 分钟内再运行一次 `vps-traffic-guard ports confirm`，否则自动撤销。

## 关闭用不到的端口（可选）

一句话：**列出对公网开着、但不是你登录、上网、建站用的端口（比如 6379 Redis），问你要不要从外面关掉；本机程序照常能用，3 分钟内不确认就自动撤销。**

安装时会显示类似这样的清单，然后问一句（直接回车 = 不关）：

```
  对公网开放的端口：
    保留  22/tcp     sshd（SSH）
    保留  80/tcp     nginx（网站/代理常用端口）
    保留  443/tcp    xray（网站/代理常用端口）
    保留  54321/tcp  x-ui
    关闭  6379/tcp   redis-server（Redis 数据库）
  要从外面关掉 6379/tcp 吗？输入 y 关闭，直接回车不关 [N]:
```

**只关认得出的高风险服务**：程序名和端口号都对得上才算，目前是 MySQL/MariaDB（3306、33060）、PostgreSQL（5432）、Redis（6379）、MongoDB（27017）、Memcached（11211）、rpcbind（111）、Docker 远程接口（dockerd 的 2375）。

**永远不关**：

- SSH 端口（sshd 配置、ssh.socket、正在使用的 SSH 连接、配置里的不限速端口）；
- 80、443（TCP 和 UDP）；
- 面板、代理（xray、sing-box、hysteria 等）、Docker 容器端口、没有程序名的内核端口（如 WireGuard），以及所有认不出用途的程序；
- 只听本机（127.0.0.1）或其他网卡地址（如 Docker 网桥、WireGuard）的端口：从外网网卡连不到，不列出；
- 上面表里的服务如果此刻正有外网连接，算“在用”，也保留。

**怎么做到不把你锁在外面**：

1. 改防火墙之前，先用 `systemd-run` 设一个 3 分钟后自动撤销的保险。这个保险不依赖本脚本，直接删掉本工具的规则。
2. 规则生效后，在同一个窗口里问你“还能正常操作吗”。150 秒内输入 `y` 才保存；超时、断线或输入别的都会撤销，恢复原样。
3. 规则里只有上面那几个端口，SSH 端口在下规则前会再过滤一遍，就算列表文件被改坏也不会关 SSH。
4. 没有 `systemd-run` 就不改防火墙。

**不碰别人的防火墙**：

- 规则只放在本工具自己的 nft 表 `inet vps_traffic_guard` 里；系统没有 nft 时，用 iptables / ip6tables 自己的链 `VTG_PORTS`。是不是本工具的规则只看这两个名字，卸载和 `ports off` 只删它们。
- ufw 或 firewalld 已经启用时不改，只提示你用它们来关。
- 只挡从外网网卡（默认路由那块网卡）进来的新连接：TCP 只丢建立连接的第一个包（SYN），不需要连接跟踪；已经建立的连接、本机自己访问、Docker 网桥和 WireGuard 等其他网卡都不受影响。IPv4、IPv6 都挡。
- 每分钟的定时任务不碰防火墙。确认后会启用 `vps-traffic-guard-ports.service`，开机时按 `/etc/vps-traffic-guard.ports` 里的列表恢复规则。

装好以后也可以随时用命令管理：

```bash
vps-traffic-guard ports             # 列出对公网开放的端口：哪些保留、哪些可以关
vps-traffic-guard ports close       # 关掉认得出的高风险端口（同样先试用、再确认）
vps-traffic-guard ports close 3307  # 指定端口（3307 = TCP+UDP，也可写 3307/tcp）
vps-traffic-guard ports open 6379   # 重新打开某个端口
vps-traffic-guard ports off         # 全部打开，本工具不再改防火墙
```

手动指定端口也受同样的保护：SSH、80/443 会被去掉；端口正被面板、代理或认不出的程序占着，或正有外网连接时，也不关，并告诉你是哪个程序在用。

试关时如果断线、没来得及确认，保险会自动撤销。要是保险本身也没了（比如试用中途重启），`status` 不再显示“试用中”，下次运行 `ports close`、`ports open` 或 `ports off` 时会把这次试用作废，不会卡住。

## 常用命令

```bash
vps-traffic-guard status          # 本期用量、今日额度、是否在限速、最近事件
vps-traffic-guard check           # REALITY 回落目标体检
vps-traffic-guard set-used 456.7  # 按商家面板校准本期已用（GB）
vps-traffic-guard pause           # 暂停限速（仍然计数）
vps-traffic-guard resume          # 恢复自动限速
vps-traffic-guard ports           # 查看对公网开放的端口（关端口见上文）
vps-traffic-guard uninstall       # 卸载，并撤销限速和本工具关闭的端口
```

配置文件在 `/etc/vps-traffic-guard.conf`，改完下一分钟自动生效。

## 它具体做了什么

- 每分钟读取一次网卡计数（`/sys/class/net/<网卡>/statistics`），累加到本期用量。状态保存在 `/var/lib/vps-traffic-guard/`，重启不清零；关机前也会保存一次。
- 需要限速时，在网卡出口加一个 HTB 队列（句柄固定为 `7e5d:`）：SSH 端口的回包走不限速通道，其他流量走限速通道。代理是“收一份、转发一份”，出口一限，进站也会跟着降下来。
- 不需要限速时删除这个队列，网卡回到系统默认队列（如 BBR 常用的 `fq`）。是不是本工具加的规则，只看网卡上的实际句柄，不依赖状态文件，所以状态文件丢失或损坏也能撤掉。
- **不碰别人的规则**：只替换内核自动挂的默认队列（句柄都是 `0:`）。网卡上只要有人手动加过队列，不管是根队列还是子队列（例如 BBR 脚本用 `tc` 加的 `fq`，或你自己的 `htb`、`cake`），它都不会覆盖，也不会删除，只在 `status` 里提示“不做限速”。限速不修改 iptables / nftables，也不关机、不断网卡；只有你选择关端口时，才会在本工具自己的 nft 表（或 iptables 链）里加规则。
- 配置文件被改坏时，它会撤掉自己加的限速，宁可不限，也不留下撤不掉的规则。限速期间修改不限速端口或网卡，下一分钟按新配置重建。
- `check` 会读取常见位置的配置（官方 Xray 安装脚本、3x-ui、sing-box 及部分一键脚本的默认路径，以及正在运行的 xray / sing-box 进程参数里指定的配置），解析 `target` 的 IP，与 Cloudflare 官方公布的 IP 段比对。有 curl 时还会请求一次目标网站，按响应头推测其他 CDN。

## 已知限制

- **本机计数和商家面板会有出入**（统计口径、重启瞬间等），所以默认只用到 90%。发现对不上时，用 `set-used` 按面板校准。
- 部分商家的内网有大量广播、扫描小包，会算进本机的入站计数（实测某台便宜 VPS 闲置一天约 1.4 GB）。商家面板未必计入这部分，本机统计可能偏高，偏差方向是安全的。过几天对一下面板，差得多就用 `set-used` 校准。
- 每日额度按 VPS 的系统时区在 0 点切换（多数 VPS 默认是 UTC，即北京时间早上 8 点）。
- 只统计一块网卡（默认是默认路由所在的网卡）。
- OpenVZ / LXC 等容器型 VPS 往往不允许改队列。这种情况下计数照常进行，限速会失败，并在 `status` 里提示。
- `check` 对 Cloudflare 的判断以官方 IP 段为准；其他 CDN 只是推测。配置放在非常规位置时，用 `check --file` 指定。
- 关端口只处理关的那一刻已在监听、又认得出的服务。以后新装的服务不会自动关，可以再运行一次 `vps-traffic-guard ports close`。数据库改了默认端口的，不会自动识别，可以用 `ports close 端口号` 指定；但用别的程序名运行、或和认不出的程序共用端口的，手动指定也不关。
- 关端口挡的是从外网网卡进来的所有连接。AWS、GCP、Oracle 这类云服务器的外网网卡本身是内网地址，所以同一内网（VPC）里的其他机器也会连不上被关的端口；数据库要给同内网的机器用时，不要关它。
- 关端口挂在 INPUT 上，管不到 Docker 用 `-p` 发布的端口（这些流量走 FORWARD）。数据库跑在 Docker 里时，请把端口绑定到 `127.0.0.1:端口`。
- 别的程序整个清空防火墙时（比如 `nft flush ruleset`、`iptables-restore` 恢复旧规则），本工具的端口规则会跟着消失，直到下次开机或运行 `vps-traffic-guard ports restore`。`status` 会提示“规则现在不在”。

## 测试情况

- `tests/run-tests.sh` 是离线逻辑测试（113 项），用假的网卡计数、假的 tc、假的时间驱动脚本。覆盖范围：账期计算（含短月、跨年、0 点切换夏令时）、每日额度、限速切换、重启、校准、新账期、状态与实际规则失步、限速中改端口和换网卡（含旧网卡撤销失败后重试）、网卡名写错、配置损坏、不覆盖他人 tc 规则（含子队列）、Cloudflare 网段判断、配置提取、SSH 端口识别、安装 / 卸载流程、selftest 流程。
- 假 tc 不校验命令语法，所以另外在真实 VPS 上跑了 `selftest`：Ubuntu 22.04.5（KVM，内核 5.15，默认队列 fq + BBR）上 17 项全部通过。设 1 Mbps 限速时实测出站 0.99 Mbps（不限速时 353 Mbps）；SSH 走不限速通道；撤销后恢复 `fq 0:`；systemd 单元通过 `systemd-analyze verify`。
- 同一台 VPS 上安装后：定时器每分钟运行；用 `set-used` 把本期已用调到触发线以上，会立即限速 403 kbit/s，与公式算出的一致，跨过定时器运行后仍保持；网卡上确实挂上 `htb 7e5d:`；改回真实用量后恢复满速，队列回到 `fq 0:`。
- 跨过一个 0 点后：剩余天数从 19 变成 18，今日额度按公式重算（95.4 → 100.7 GB），状态文件里的计数和网卡实时计数一致。
- **还没在真实 VPS 上验证的**：重启后续算、新账期切换。这些目前只有离线测试覆盖。
- 关端口（0.2.0 新增）：离线测试共 244 项（含上面的部分），用假的 ss、nft、iptables / ip6tables、systemctl、systemd-run 驱动。覆盖：端口分类（认得出 / 认不出 / 多个程序共用 / 正有外网连接 / 只听本机 / SSH / 80、443）、不选关端口时一次都不调用防火墙命令、`--yes --close-ports` 试用与确认、交互 y / n / 超时 / 断线、超时自动撤销、试用中途重启后作废、手动指定在用端口被拒、ufw / firewalld 启用时跳过、nft 预检失败、iptables 后备、开机恢复、卸载只删本工具的规则。
- 短安装入口 `i`：离线测试覆盖正常安装和参数透传；下载到网页、截断的主脚本（包括截在两个函数之间、`bash -n` 照样能通过的那种）、下载失败时都会停下，不覆盖已装的版本；`i` 自己没收完整时什么都不执行。
- 假 nft / iptables 不校验规则语法，所以关端口也在同一台真实 VPS 上测过（Ubuntu 22.04.5，KVM，内核 5.15，nftables 1.0.2，iptables 1.8.7 nf_tables 后端），38 项全部通过：
  - 用 `install --yes` 从 0.1.0 升级到 0.2.0，没选关端口时不碰防火墙。升级后状态里仍是原来的不限速端口和面板校准值（这一点是看状态输出确认的，没有单独断言）。
  - 扫描真实端口：SSH、网站、代理端口全部保留，没有建议关的。
  - 用一个假的 memcached（11211）测：真实 systemd 定时器 40 秒后自动撤销；在模拟终端里运行 `ports close 11211`，输入 n 撤销，输入 y 保存并启用开机恢复。
  - nft 规则被内核接受（显示为 `tcp flags syn / syn,ack ... drop`），规则里没有 SSH、80、443。
  - 从外网的 Windows 电脑连 11211 四次：VPS 上的假服务一次都没收到连接，本工具规则的计数增加；没被关的对照端口照常能连。（电脑这边 4 次都显示“连上但没回应”，说明本地网络里有东西先接了握手，例如代理，所以结论以 VPS 端为准。）
  - 模拟规则被清掉，再启动开机恢复服务，规则会加回来。
  - iptables / ip6tables 后备可用；全部打开后不留规则、单元和测试进程。
- 真机测试之后又做了一轮审查修正（以前用 iptables 关过、后来装上 nft 时清掉旧的 iptables 规则；Ctrl-C 时的提示；说明文字），这些只有离线测试。
- **关端口还没在真机上验证的**（只有离线测试覆盖）：
  - 安装命令里的那一问（交互安装），以及 `install --yes --close-ports`。它们和上面测过的 `ports close` 走同一段代码。
  - 真正重启后的恢复（上面是手动启动恢复服务来模拟的）。
  - 关着端口时卸载。
  - 从外网测 IPv6。
  - ufw / firewalld 启用时跳过。
  - 容器型 VPS 上预检失败。

```bash
bash tests/run-tests.sh
```
