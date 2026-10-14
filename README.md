# Kubernetes 学习笔记

https://kubernetes.io/zh-cn/docs/home/

https://kubernetes.feisky.xyz/extension/ingress



基于 RHEL 9 三节点实验环境整理的 Kubernetes 实操记录，涵盖集群搭建、常见工作负载与网络存储实验，以及 WordPress + MySQL 持久化项目。

## 阅读顺序

| 章节 | 内容 |
| --- | --- |
| [01 集群搭建与初始化](01-K8s集群搭建与初始化.md) | 环境准备、手动安装、Flannel、节点加入与脚本安装；两种安装流程择一执行。 |
| [02 应用部署与管理](02-K8s应用部署与管理.md) | 管理界面、应用基础、存储、网站入口、健康与资源、工作负载、权限、调度与维护。 |
| [03 WordPress + MySQL 持久化博客](03-k8s%20部署%20WordPress%20%2B%20MySQL%20持久化博客.md) | 独立综合项目：部署、访问、数据查询、Pod 重建与暂停恢复。 |

## 配套文件

- [安装脚本](脚本/k8s-setup.sh)及[配置样例](脚本/k8s-setup.conf)：用于 RHEL 9 实验集群。先阅读第 01 章，并运行 `bash k8s-setup.sh --help` 和 `bash k8s-setup.sh plan ...` 核对参数。
- [WordPress 项目配置](wordpress-demo/)：包含 `kustomization.yaml`、存储、MySQL 和 WordPress 四份 YAML。部署步骤见第 03 章。
- [根分区被误注释的排错记录](排错/根分区被误注释.md)：记录故障现象、修复过程和验证结果。

