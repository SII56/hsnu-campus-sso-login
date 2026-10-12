# hsnu-campus-sso-login

韩师校园网无头登录。没有浏览器、没有桌面客户端也能认证上网。

仓库里两个脚本：`campus-sso-login.sh`（Linux / macOS）和 `campus-sso-login.ps1`（Windows）。

```bash
git clone https://github.com/SII56/hsnu-campus-sso-login.git
cd hsnu-campus-sso-login
```

## Windows

```powershell
powershell -ExecutionPolicy Bypass -File .\campus-sso-login.ps1
```

会提示输入学号和密码（密码不回显）。其它参数：

```powershell
powershell -ExecutionPolicy Bypass -File .\campus-sso-login.ps1 -Check    # 只看在不在线
powershell -ExecutionPolicy Bypass -File .\campus-sso-login.ps1 -DryRun   # 走完整条链路，但不提交密码
powershell -ExecutionPolicy Bypass -File .\campus-sso-login.ps1 -Logout   # 注销
powershell -ExecutionPolicy Bypass -File .\campus-sso-login.ps1 -Force    # 忽略在线状态，强制认证
```

需要 Windows 10 1803 以上（要用系统自带的 `curl.exe`）和 PowerShell 5.1 以上。

不想每次输密码，就在脚本同目录建一个 `campus.conf.ps1`：

```powershell
$CAMPUS_USER = "202412345678"
$CAMPUS_PASS = "your-password"
```

## Linux / macOS

```bash
chmod +x campus-sso-login.sh

./campus-sso-login.sh            # 已在线就跳过，否则认证
./campus-sso-login.sh --check
./campus-sso-login.sh --dry-run
./campus-sso-login.sh --logout
./campus-sso-login.sh --force
```

## 注销做了什么

按**浏览器真实发出的请求**（用 DevTools 导出 HAR 抓到的）依次两步：

**1. 解绑终端 MAC —— 这一步才是真正断网的**

```
GET https://<门户>:802/eportal/portal/mac/unbind
      ?callback=dr1002&user_account=<学号>&wlan_user_mac=000000000000
      &wlan_user_ip=<本机IP>&wlan_user_ipv6=::&unbind_type=1
      &jsVersion=4.2.2&program_index=..&page_index=..&v=..&lang=..
    -> {"result":1,"msg":"Unbind Terminal Mac successful!"}
```

注意这里**不是** `/drcom/logout`。门户 JS 在 `unBindMac == 1` 时走的是
`user.unbind_mac()` 分支，而 `/drcom/logout` 对走统一身份认证建立的会话会回
`Logout Error(no webmode)`。照抄前者才对。

**2. 注销 CAS 单点登录**

```
GET https://<门户>:802/eportal/portal/cas/logout?...
    -> {"result":1,"switch_uri":"https://hscas.hstc.edu.cn/cas/logout?..."}
```

拿到 `switch_uri` 后还要跟过去，CAS 那边的登录态才会清掉。

脚本会先调 `chkstatus` 取出自己的 `uid`（账号）和 `ss5`（门户眼中的本机 IP），
再用它们组装上面两条请求。请求都带 `Referer: https://<门户>/`。

> 注销后你会掉线。想省事可以用 `--logout --relogin`，脚本会注销后自动登回来。

## 账号密码

```bash
cp campus.conf.example campus.conf
chmod 600 campus.conf
vi campus.conf
```

不写也行，会在终端里提示输入。

> 只有 CAS 真的要你填登录表单时才会问密码。如果 CAS 已经认得这台机器（IP 级 SSO），
> 它会直接发 ticket，全程不需要密码。

**脚本不保存任何密码**：密码只在这个进程的内存里，从 stdin 交给 curl，
不会出现在 `ps` 的命令行里；`cookies.txt`（可能含 CAS 会话 cookie）退出时自动删除，
工作目录权限 700。

## 出问题看这里

日志：`/tmp/campus-sso-login.log`
现场文件：`/tmp/campus-sso/`（Windows 是 `%TEMP%\campus-sso\`）

| 文件 | 看什么 |
|---|---|
| `cas-login.html` | CAS 返回的页面，确认有没有 `execution` |
| `post.html` | 提交密码后 CAS 的回复，密码错会写在这里 |

## 注意

- `campus.conf` 里是明文密码，权限设成 `600`，别提交到仓库。
- 脚本只做登录/注销，不改任何网络配置。

## License

CC0-1.0，见 [LICENSE](LICENSE)。
