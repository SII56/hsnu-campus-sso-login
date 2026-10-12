# campus-sso-login

韩师校园网无头登录。没有浏览器、没有桌面客户端也能认证上网。

## Windows

```powershell
git clone ...
cd ...
```

```powershell
powershell -ExecutionPolicy Bypass -File .\campus-sso-login.ps1
```

会提示输入学号和密码（密码不回显）。其它参数：

```powershell
... -Check      # 只看在不在线
... -DryRun     # 走完整条链路，但不提交密码
... -Force      # 忽略在线状态，强制认证
```

## Linux / macOS
```zsh
git clone ...
cd ...
```
```bash
chmod +x campus-sso-login.sh

./campus-sso-login.sh            # 已在线就跳过，否则认证
./campus-sso-login.sh --check
./campus-sso-login.sh --dry-run
./campus-sso-login.sh --force
```

账号密码可以写进 `campus.conf`（`cp campus.conf.example campus.conf`，再 `chmod 600`），
不写就在终端里提示输入。

> 只有 CAS 真的要你填登录表单时才会问密码。如果 CAS 已经认得这台机器
> （IP 级 SSO），它会直接发 ticket，全程不需要密码。


## 出问题看这里

日志：`/tmp/campus-sso-login.log`
现场文件：`/tmp/campus-sso/`（Windows 是 `%TEMP%\campus-sso\`）

| 文件 | 看什么 |
|---|---|
| `cas-login.html` | CAS 返回的页面，确认有没有 `execution` |
| `post.html` | 提交密码后 CAS 的回复，密码错会写在这里 |

## 注意

- `campus.conf` 里是明文密码，权限设成 `600`，别提交到仓库。
- 脚本只做登录，不改任何网络配置。
