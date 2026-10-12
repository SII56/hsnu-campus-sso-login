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

按门户自己代码里的顺序，两步：

1. `GET <门户>/drcom/logout` —— 断掉上网会话
2. `GET <门户>:801/eportal/portal/cas/logout` —— 同步注销 CAS 单点登录

第 2 步是韩师专门定制的（门户 JS 里就写着「韩山师范学院 同步注销单点登录」），
如果不做，CAS 那边的登录态还在，下次可能免密直接又登上。

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
