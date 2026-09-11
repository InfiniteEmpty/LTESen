# 当前列锚定的联合二维 MUSIC / R-D 试验

真实数据入口为工程根目录的 `LTE_CRS_sense_flow_CSI_compute.m`，也可以运行本目录下的 `run_real_data_continuous_csi.m`。原有读取、同步、CSI 校正和静态消减保持不变；Step F 使用同一个 `AnchoredSincResampler` 生成两种显示：

- 上图：指数递推累加的联合距离/多普勒自相关，再作二维 MUSIC 子空间扫描。
- 下图：同一插值器的完整 200 列当前窗口作 2D-FFT R-D，不跨窗口累加。

## 锚定插值与联合相关

插值后的列按“最新到最旧”排列：

```text
y_k(j) = x_k(m - alpha_k*j),   alpha_k = fc/F_k,   j = 0,1,...
```

最新列与输入 CSI 严格相同。`F_k` 使用实际射频频率，因此各载波的时间缩放对齐到中心载波的多普勒。完整窗口和 `P_t+1` 列短快照由同一状态导出，所以插值锚点不会分叉。为了避免每个样本都维护 200 个输出列，状态递推维护 MUSIC 相关孔径需要的前 `P_t+1` 列；到显示时再从同一原始历史以同一 sinc 定义直接计算 200 列，不是第二个插值器。

对每个新慢时间样本，直接生成整个联合矩阵：

```text
q(df,dt) = mean_f x(f,n) * conj(x(f-df*DeltaF,n-dt))
N         = lambda*N + q
W         = lambda*W + 1
r         = N/W
```

`df=-P_r:P_r`，`dt=0:P_t`。距离与多普勒 lag 在一次复数乘积中联合形成，没有先求一维功率或先压缩子载波，所以保留了后一维所需的相位。程序仅长期保存这个自相关矩阵，不保存完整协方差矩阵。

LTE DC 未使用。`Recursive2DAutocorrelation` 按实际频率搜索 `f-df*DeltaF` 配对，没有把 DC 两侧的相邻数组行错当成一个 CRS 间隔。

## 二维 MUSIC 谱

`jointMusicRangeDopplerSpectrum` 用已累积的 lag 矩阵临时构造尺寸为 `(P_r+1)(P_t+1)` 的块 Toeplitz 协方差矩阵。对

```text
a(omega_r,omega_t)[p,q] = exp(-j*(p*omega_r+q*omega_t))
```

用最大的 `musicSignalCount` 个特征向量构成信号子空间。MUSIC 分母为 `a'*En*En'*a`。实现中利用 `||a||^2-a'*Es*Es'*a` 的等价式，只对少量信号特征向量做 2D-FFT，避免在每个距离–多普勒网格上遍历整个噪声子空间。

负时间 lag 由 `r(-df,-dt)=conj(r(df,dt))` 补全。若估计协方差不定，求谱阶段会增加对角加载，但不修改长期递推相关。标题中的 `eigengap=lambda_D/lambda_(D+1)` 可用来观察所选信号数 `D` 是否有明显的特征值分界。

原二维 AR 求解器仍保留在工程中，仅用于仿真对照 MUSIC 与二维全极点模型的斜峰脊。

距离坐标使用 `R=-omega_r*c/(4*pi*DeltaF)`，速度坐标使用 `v=-f_d*c/(2*fc)`。这是 `c/2` 等效单站换算；在被动双站场景中应解释为等效路径/路径变化率。

## 主要参数

| 参数 | 默认 | 用途 |
| --- | --- | --- |
| `win_NFrame` | 10 | 200 点完整 R-D 窗口 |
| `jointRangeOrder` | 24 | MUSIC 虚拟子阵的频率/距离孔径减 1 |
| `jointDopplerOrder` | 24 | MUSIC 虚拟子阵的慢时间孔径减 1 |
| `musicSignalCount` | 2 | 假定的目标/信号子空间维数 |
| `jointForgettingFactor` | 0.998 | 以单个慢时间样本定义的遗忘因子 |
| `jointSpectrumUpdateSamples` | 200 | 求谱/显示间隔，不改变逐样本相关更新 |
| `musicDiagonalLoading` | `1e-3` | MUSIC 临时协方差的基础对角加载 |
| `resampleKernelTolerance` | `1e-8` | sinc 远场展开精度 |
| `resampleGuardSamples` | 12 | 插值的较旧额外历史支持 |

`jointRangeOrder` 和 `jointDopplerOrder` 共同决定虚拟协方差尺寸 `(P_r+1)(P_t+1)`。增大孔径可以提高分辨率，但会增大特征分解成本，并且需要更稳定的相关估计。

## 验证

双目标 AR / MUSIC / 2D-FFT 对照仿真：

```matlab
run('test_script/continuous_csi/simulations/simulate_joint_2d_music_range_doppler.m')
```

```matlab
run('test_script/run_all_unit_tests.m')
```

测试覆盖：完整/短快照共用插值结果、跨 DC 实际频率配对、指数递推闭式结果、联合二维相位保留、双目标 MUSIC 点峰和特征值间隔，以及求谱对长期相关状态的只读性。
