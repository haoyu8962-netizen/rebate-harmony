#!/bin/bash
# 合成件（FU-HM-TAB-BAR 守卫自测；不进构建）：注释里提到 tabbar 不算，只认下面的 case 行。
case "$DEVICE_SET" in main|me12wc|tabbar|all) ;; *) exit 2 ;; esac
