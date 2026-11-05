## 外部依赖升级

| 组件 | 类型 | 旧 | 新 | 上游时间 |
| --- | --- | --- | --- | --- |
| oxidns | release | `1.6.0` | `1.6.1` | v1.6.1 |

内核的 SHA256 已随版本一起重算；合并前请先验证构建：

```bash
gh workflow run build.yml --ref chore/bump-external
```
