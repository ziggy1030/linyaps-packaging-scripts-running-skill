# linyaps-packaging-scripts-running-skill SKILL设计需求

## SKILL目的
创建一个SKILL用于自动执行脚本来打包已经适配好便捷打包脚本的玲珑项目， 这些已经适配便捷打包的项目有鲜明特征，即项目根目录下可以看到脚本`pak_linyaps.sh`

## 业务流程
1. 根据用户提供的json文件去获取当前任务的基本信息，尤其是src_url、arch、pkgName，必选内容是: src_url、arch、output_dir、orig_version、pkgName、已经适配便捷打包的项目所在路径、src_dir
2. 在当前工作目录下设置build_tmp_dir、output_dir(如果用户未指定)、src_dir(如果用户未指定)
3. 根据用户提供的src_url提取orig_version(如果用户未指定)，下载原始资源到src_dir并记录
3.5 架构匹配验证：使用 arch_mapping.json 映射表比对 src_url 中的架构特征与 tasks[].arch 是否匹配。匹配成功则继续；匹配失败则报错跳过；无法识别则输出LLM分析请求但不阻断流程
4. 根据用户提供的json，依次解析每个任务的pkgName和对应子信息
5. 找到已经适配便捷打包的项目所在路径，根据用户提供的pkgName定位对应的打包项目
6. 参考模板和信息生成打包命令
```bash
./pak_linyaps.sh \
  --linyaps_arch=x86_64 \
  --origin_version=151.0 \
  --src_path="/media/deepin/Data/top100-CI/src/260521-ai/firefox-151.0.en-US.linux-x86_64.tar.xz" \
  --output_dir="/media/deepin/Data/top100-CI/out/260521-ai" \
  --build_tmp_dir=/home/deepin/.cache/260521-ai
```
7. 可以考虑后台执行，只记录最后数行输出，提高效率
8. 所有打包任务结束，输出结果统计

## 参考资料
 - 目录`demo-files`: 放置了已经适配便捷打包的演示项目