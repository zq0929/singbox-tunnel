把你的证书放在这个目录（与 start.sh 同级）：

  fullchain.pem   证书链：叶子证书在前，中间证书在后（顺序不能反）
  privkey.pem     私钥：未加密（不能带 passphrase），权限 600

也支持这些文件名（任选其一成对出现）：
  cert.pem / chain.pem      + privkey.pem / key.pem / private.key

放好后直接重启容器即可，start.sh 的 CERT_MODE=auto 会自动发现并校验。
不放心可以先干跑：DRY_RUN=1 bash start.sh

注意：
- 若两个文件只有一个存在，脚本会报错退出，不会自动补一个。
- 若校验失败（过期/不匹配/格式错），脚本会报错，并且**不会覆盖**你的文件。
- 想强制用自签证书：CERT_MODE=selfsigned
