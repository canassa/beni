# Generated measurements

All sizes are bytes, timings milliseconds. Interquartile ranges use linear interpolation.

## repeated feature growth

| Family | Mode | N=1 | N=4 | N=16 | N=64 | Intercept | B/feature | R² |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| dashboard | vanilla | 474 | 475 | 476 | 476 | 474.8 | 0.02 | 0.473 |
| dashboard | lexical | 485 | 487 | 491 | 491 | 486.9 | 0.07 | 0.524 |
| dashboard | indexed | 536 | 537 | 539 | 539 | 537.0 | 0.04 | 0.524 |
| dashboard | signals | 630 | 631 | 632 | 633 | 630.7 | 0.04 | 0.788 |
| dashboard | scan | 533 | 537 | 537 | 537 | 535.3 | 0.03 | 0.213 |
| dashboard | expanded | 485 | 733 | 1635 | 3732 | 580.8 | 50.14 | 0.986 |
| form | vanilla | 499 | 501 | 502 | 502 | 500.4 | 0.03 | 0.396 |
| form | lexical | 512 | 514 | 515 | 515 | 513.4 | 0.03 | 0.396 |
| form | indexed | 558 | 559 | 560 | 560 | 558.8 | 0.02 | 0.473 |
| form | signals | 647 | 649 | 650 | 651 | 648.2 | 0.05 | 0.650 |
| form | scan | 560 | 561 | 564 | 564 | 561.1 | 0.05 | 0.539 |
| form | expanded | 493 | 790 | 1748 | 4770 | 531.3 | 66.78 | 0.997 |
| crud | vanilla | 751 | 753 | 754 | 754 | 752.4 | 0.03 | 0.396 |
| crud | lexical | 752 | 752 | 755 | 755 | 752.6 | 0.04 | 0.549 |
| crud | indexed | 808 | 809 | 808 | 808 | 808.4 | -0.01 | 0.155 |
| crud | signals | 878 | 888 | 881 | 891 | 881.5 | 0.14 | 0.483 |
| crud | scan | 813 | 812 | 811 | 811 | 812.2 | -0.02 | 0.473 |
| crud | expanded | 748 | 1159 | 2521 | 6544 | 824.4 | 90.29 | 0.995 |
| board | vanilla | 572 | 572 | 573 | 573 | 572.2 | 0.01 | 0.549 |
| board | lexical | 572 | 573 | 568 | 568 | 571.6 | -0.07 | 0.526 |
| board | indexed | 623 | 623 | 625 | 625 | 623.4 | 0.03 | 0.549 |
| board | signals | 717 | 717 | 719 | 718 | 717.5 | 0.01 | 0.148 |
| board | scan | 619 | 618 | 619 | 620 | 618.5 | 0.02 | 0.702 |
| board | expanded | 561 | 862 | 1907 | 5377 | 571.2 | 75.55 | 0.998 |
| route | vanilla | 869 | 871 | 873 | 873 | 870.5 | 0.05 | 0.473 |
| route | lexical | 876 | 878 | 879 | 880 | 877.2 | 0.05 | 0.650 |
| route | indexed | 929 | 931 | 932 | 932 | 930.4 | 0.03 | 0.396 |
| route | signals | 1022 | 1024 | 1025 | 1025 | 1023.4 | 0.03 | 0.396 |
| route | scan | 925 | 927 | 929 | 928 | 926.6 | 0.03 | 0.236 |
| route | expanded | 878 | 1399 | 2992 | 7735 | 986.9 | 106.55 | 0.995 |
| fanout | vanilla | 523 | 525 | 527 | 527 | 524.5 | 0.05 | 0.473 |
| fanout | lexical | 542 | 543 | 545 | 545 | 543.0 | 0.04 | 0.524 |
| fanout | indexed | 592 | 594 | 596 | 596 | 593.5 | 0.05 | 0.473 |
| fanout | signals | 685 | 687 | 687 | 687 | 686.2 | 0.02 | 0.213 |
| fanout | scan | 584 | 587 | 589 | 589 | 586.1 | 0.05 | 0.429 |
| fanout | expanded | 529 | 803 | 1687 | 3943 | 619.9 | 52.73 | 0.990 |

## varied feature growth

| Family | Mode | N=1 | N=4 | N=16 | N=64 | Intercept | B/feature | R² |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| dashboard | vanilla | 480 | 818 | 1984 | 5105 | 571.1 | 71.79 | 0.992 |
| dashboard | lexical | 485 | 781 | 1866 | 4491 | 588.2 | 62.00 | 0.988 |
| dashboard | indexed | 520 | 876 | 2048 | 5709 | 566.3 | 81.03 | 0.997 |
| dashboard | signals | 621 | 989 | 2236 | 5617 | 717.7 | 77.55 | 0.993 |
| dashboard | scan | 523 | 853 | 1933 | 4529 | 648.0 | 61.72 | 0.987 |
| dashboard | expanded | 485 | 781 | 1866 | 4491 | 588.2 | 62.00 | 0.988 |
| form | vanilla | 500 | 838 | 2067 | 5571 | 563.0 | 79.11 | 0.995 |
| form | lexical | 493 | 822 | 1967 | 5502 | 531.6 | 78.32 | 0.997 |
| form | indexed | 542 | 904 | 2196 | 5671 | 633.9 | 79.73 | 0.993 |
| form | signals | 643 | 1040 | 2370 | 6024 | 743.8 | 83.55 | 0.993 |
| form | scan | 544 | 879 | 2073 | 5755 | 580.0 | 81.54 | 0.997 |
| form | expanded | 493 | 822 | 1967 | 5502 | 531.6 | 78.32 | 0.997 |
| crud | vanilla | 764 | 1236 | 2808 | 7670 | 828.0 | 107.84 | 0.997 |
| crud | lexical | 750 | 1211 | 2717 | 7280 | 826.3 | 101.80 | 0.996 |
| crud | indexed | 803 | 1300 | 2796 | 7949 | 836.8 | 111.78 | 0.998 |
| crud | signals | 898 | 1398 | 2845 | 6229 | 1109.1 | 81.57 | 0.984 |
| crud | scan | 800 | 1248 | 2825 | 7308 | 890.5 | 101.40 | 0.995 |
| crud | expanded | 750 | 1211 | 2717 | 7280 | 826.3 | 101.80 | 0.996 |
| board | vanilla | 562 | 929 | 2194 | 6234 | 592.7 | 88.80 | 0.998 |
| board | lexical | 560 | 896 | 2109 | 6139 | 563.9 | 87.63 | 0.998 |
| board | indexed | 611 | 985 | 2243 | 5378 | 739.0 | 73.66 | 0.989 |
| board | signals | 708 | 1116 | 2336 | 6097 | 783.2 | 83.81 | 0.996 |
| board | scan | 608 | 951 | 2160 | 6104 | 624.2 | 86.19 | 0.998 |
| board | expanded | 560 | 896 | 2109 | 6139 | 563.9 | 87.63 | 0.998 |
| route | vanilla | 883 | 1436 | 3221 | 8268 | 1015.1 | 114.68 | 0.994 |
| route | lexical | 879 | 1419 | 3156 | 8185 | 996.3 | 113.57 | 0.995 |
| route | indexed | 932 | 1480 | 3163 | 9376 | 920.0 | 132.60 | 0.999 |
| route | signals | 1037 | 1613 | 3448 | 9554 | 1081.3 | 133.26 | 0.998 |
| route | scan | 931 | 1459 | 3239 | 8113 | 1065.6 | 111.52 | 0.993 |
| route | expanded | 879 | 1419 | 3156 | 8185 | 996.3 | 113.57 | 0.995 |
| fanout | vanilla | 533 | 887 | 2081 | 5245 | 634.2 | 73.05 | 0.992 |
| fanout | lexical | 526 | 847 | 1972 | 4702 | 640.3 | 64.54 | 0.988 |
| fanout | indexed | 578 | 938 | 2185 | 5975 | 627.3 | 84.31 | 0.996 |
| fanout | signals | 687 | 1054 | 2339 | 5723 | 790.0 | 78.15 | 0.992 |
| fanout | scan | 572 | 908 | 2090 | 4827 | 705.1 | 65.61 | 0.986 |
| fanout | expanded | 526 | 847 | 1972 | 4702 | 640.3 | 64.54 | 0.988 |

## Event batches

| Family | Shape | N | Mode | Operation | Events/batch | Median [Q1–Q3], ms |
|---|---|---:|---|---|---:|---:|
| board | varied | 1 | expanded | step | 100 | 0.415 [0.400–0.420] |
| board | varied | 64 | expanded | step | 100 | 0.395 [0.395–0.405] |
| board | varied | 1 | indexed | step | 100 | 0.500 [0.500–0.525] |
| board | varied | 64 | indexed | step | 100 | 0.510 [0.500–0.515] |
| board | varied | 1 | lexical | step | 100 | 0.420 [0.410–0.430] |
| board | varied | 64 | lexical | step | 100 | 0.400 [0.380–0.410] |
| board | varied | 1 | scan | step | 100 | 0.390 [0.385–0.410] |
| board | varied | 64 | scan | step | 100 | 1.415 [1.375–1.460] |
| board | varied | 1 | signals | step | 100 | 0.595 [0.585–0.615] |
| board | varied | 64 | signals | step | 100 | 0.560 [0.545–0.575] |
| board | varied | 1 | vanilla | step | 100 | 0.405 [0.405–0.410] |
| board | varied | 64 | vanilla | step | 100 | 0.400 [0.400–0.415] |
| crud | population | 100 | expanded | edit | 10 | 0.320 [0.315–0.325] |
| crud | population | 100 | expanded | swap | 10 | 0.965 [0.950–0.975] |
| crud | population | 1000 | expanded | edit | 10 | 2.075 [2.065–2.090] |
| crud | population | 1000 | expanded | swap | 10 | 9.345 [9.200–9.470] |
| crud | population | 10000 | expanded | edit | 10 | 17.985 [17.860–18.035] |
| crud | population | 10000 | expanded | swap | 10 | 102.050 [100.560–102.600] |
| crud | population | 100 | indexed | edit | 10 | 0.320 [0.315–0.325] |
| crud | population | 100 | indexed | swap | 10 | 0.970 [0.960–0.990] |
| crud | population | 1000 | indexed | edit | 10 | 2.100 [2.060–2.115] |
| crud | population | 1000 | indexed | swap | 10 | 9.280 [9.205–9.415] |
| crud | population | 10000 | indexed | edit | 10 | 18.220 [18.090–18.540] |
| crud | population | 10000 | indexed | swap | 10 | 104.545 [103.070–105.185] |
| crud | population | 100 | lexical | edit | 10 | 0.320 [0.315–0.320] |
| crud | population | 100 | lexical | swap | 10 | 0.995 [0.980–1.005] |
| crud | population | 1000 | lexical | edit | 10 | 2.055 [2.030–2.065] |
| crud | population | 1000 | lexical | swap | 10 | 9.235 [9.125–9.305] |
| crud | population | 10000 | lexical | edit | 10 | 18.090 [18.020–18.135] |
| crud | population | 10000 | lexical | swap | 10 | 102.540 [101.450–102.715] |
| crud | population | 100 | scan | edit | 10 | 0.320 [0.315–0.325] |
| crud | population | 100 | scan | swap | 10 | 0.955 [0.950–0.980] |
| crud | population | 1000 | scan | edit | 10 | 2.055 [2.035–2.060] |
| crud | population | 1000 | scan | swap | 10 | 9.295 [9.165–9.315] |
| crud | population | 10000 | scan | edit | 10 | 17.845 [17.780–18.080] |
| crud | population | 10000 | scan | swap | 10 | 102.395 [100.835–104.135] |
| crud | population | 100 | signals | edit | 10 | 0.330 [0.325–0.335] |
| crud | population | 100 | signals | swap | 10 | 1.010 [0.980–1.015] |
| crud | population | 1000 | signals | edit | 10 | 2.045 [2.035–2.095] |
| crud | population | 1000 | signals | swap | 10 | 9.395 [9.285–9.500] |
| crud | population | 10000 | signals | edit | 10 | 18.060 [18.010–18.325] |
| crud | population | 10000 | signals | swap | 10 | 103.385 [101.230–104.445] |
| crud | population | 100 | vanilla | edit | 10 | 0.320 [0.310–0.320] |
| crud | population | 100 | vanilla | swap | 10 | 0.985 [0.960–1.000] |
| crud | population | 1000 | vanilla | edit | 10 | 2.125 [2.080–2.135] |
| crud | population | 1000 | vanilla | swap | 10 | 9.310 [9.210–9.565] |
| crud | population | 10000 | vanilla | edit | 10 | 18.085 [17.805–18.685] |
| crud | population | 10000 | vanilla | swap | 10 | 101.380 [100.700–105.035] |
| crud | varied | 1 | expanded | edit | 10 | 0.155 [0.155–0.160] |
| crud | varied | 1 | expanded | swap | 10 | 0.245 [0.245–0.255] |
| crud | varied | 64 | expanded | edit | 10 | 0.095 [0.095–0.100] |
| crud | varied | 64 | expanded | swap | 10 | 0.245 [0.245–0.250] |
| crud | varied | 1 | indexed | edit | 10 | 0.160 [0.160–0.160] |
| crud | varied | 1 | indexed | swap | 10 | 0.245 [0.240–0.255] |
| crud | varied | 64 | indexed | edit | 10 | 0.105 [0.100–0.115] |
| crud | varied | 64 | indexed | swap | 10 | 0.250 [0.250–0.255] |
| crud | varied | 1 | lexical | edit | 10 | 0.155 [0.155–0.155] |
| crud | varied | 1 | lexical | swap | 10 | 0.245 [0.240–0.250] |
| crud | varied | 64 | lexical | edit | 10 | 0.105 [0.105–0.110] |
| crud | varied | 64 | lexical | swap | 10 | 0.250 [0.250–0.260] |
| crud | varied | 1 | scan | edit | 10 | 0.155 [0.150–0.155] |
| crud | varied | 1 | scan | swap | 10 | 0.250 [0.245–0.250] |
| crud | varied | 64 | scan | edit | 10 | 2.130 [2.115–2.145] |
| crud | varied | 64 | scan | swap | 10 | 1.785 [1.775–1.860] |
| crud | varied | 1 | signals | edit | 10 | 0.165 [0.160–0.175] |
| crud | varied | 1 | signals | swap | 10 | 0.260 [0.255–0.265] |
| crud | varied | 64 | signals | edit | 10 | 0.110 [0.110–0.115] |
| crud | varied | 64 | signals | swap | 10 | 0.265 [0.260–0.265] |
| crud | varied | 1 | vanilla | edit | 10 | 0.155 [0.155–0.160] |
| crud | varied | 1 | vanilla | swap | 10 | 0.245 [0.235–0.250] |
| crud | varied | 64 | vanilla | edit | 10 | 0.105 [0.105–0.105] |
| crud | varied | 64 | vanilla | swap | 10 | 0.255 [0.250–0.255] |
| dashboard | varied | 1 | expanded | inc | 100 | 0.250 [0.245–0.260] |
| dashboard | varied | 64 | expanded | inc | 100 | 0.245 [0.235–0.245] |
| dashboard | varied | 1 | indexed | inc | 100 | 0.345 [0.320–0.350] |
| dashboard | varied | 64 | indexed | inc | 100 | 0.320 [0.315–0.325] |
| dashboard | varied | 1 | lexical | inc | 100 | 0.250 [0.230–0.255] |
| dashboard | varied | 64 | lexical | inc | 100 | 0.245 [0.235–0.250] |
| dashboard | varied | 1 | scan | inc | 100 | 0.255 [0.240–0.255] |
| dashboard | varied | 64 | scan | inc | 100 | 3.030 [3.015–3.235] |
| dashboard | varied | 1 | signals | inc | 100 | 0.420 [0.400–0.420] |
| dashboard | varied | 64 | signals | inc | 100 | 0.365 [0.350–0.365] |
| dashboard | varied | 1 | vanilla | inc | 100 | 0.250 [0.240–0.255] |
| dashboard | varied | 64 | vanilla | inc | 100 | 0.245 [0.245–0.250] |
| fanout | varied | 1 | expanded | all | 100 | 0.265 [0.260–0.280] |
| fanout | varied | 1 | expanded | inc | 100 | 0.250 [0.245–0.270] |
| fanout | varied | 64 | expanded | all | 100 | 7.170 [7.165–7.260] |
| fanout | varied | 64 | expanded | inc | 100 | 0.245 [0.245–0.250] |
| fanout | varied | 1 | indexed | all | 100 | 0.315 [0.305–0.335] |
| fanout | varied | 1 | indexed | inc | 100 | 0.340 [0.320–0.340] |
| fanout | varied | 64 | indexed | all | 100 | 7.130 [7.105–7.180] |
| fanout | varied | 64 | indexed | inc | 100 | 0.325 [0.320–0.330] |
| fanout | varied | 1 | lexical | all | 100 | 0.270 [0.270–0.275] |
| fanout | varied | 1 | lexical | inc | 100 | 0.260 [0.255–0.265] |
| fanout | varied | 64 | lexical | all | 100 | 7.210 [7.175–7.450] |
| fanout | varied | 64 | lexical | inc | 100 | 0.245 [0.235–0.250] |
| fanout | varied | 1 | scan | all | 100 | 0.290 [0.280–0.305] |
| fanout | varied | 1 | scan | inc | 100 | 0.250 [0.240–0.255] |
| fanout | varied | 64 | scan | all | 100 | 8.315 [8.295–8.465] |
| fanout | varied | 64 | scan | inc | 100 | 3.050 [3.005–3.115] |
| fanout | varied | 1 | signals | all | 100 | 0.295 [0.290–0.300] |
| fanout | varied | 1 | signals | inc | 100 | 0.425 [0.420–0.445] |
| fanout | varied | 64 | signals | all | 100 | 9.050 [9.030–9.125] |
| fanout | varied | 64 | signals | inc | 100 | 0.360 [0.355–0.365] |
| fanout | varied | 1 | vanilla | all | 100 | 0.265 [0.260–0.270] |
| fanout | varied | 1 | vanilla | inc | 100 | 0.245 [0.240–0.250] |
| fanout | varied | 64 | vanilla | all | 100 | 6.940 [6.905–7.060] |
| fanout | varied | 64 | vanilla | inc | 100 | 0.240 [0.240–0.250] |
| form | varied | 1 | expanded | edit | 100 | 0.170 [0.170–0.175] |
| form | varied | 64 | expanded | edit | 100 | 0.190 [0.185–0.190] |
| form | varied | 1 | indexed | edit | 100 | 0.240 [0.235–0.255] |
| form | varied | 64 | indexed | edit | 100 | 0.260 [0.260–0.265] |
| form | varied | 1 | lexical | edit | 100 | 0.170 [0.170–0.180] |
| form | varied | 64 | lexical | edit | 100 | 0.195 [0.190–0.200] |
| form | varied | 1 | scan | edit | 100 | 0.225 [0.220–0.225] |
| form | varied | 64 | scan | edit | 100 | 1.370 [1.340–1.380] |
| form | varied | 1 | signals | edit | 100 | 0.260 [0.255–0.265] |
| form | varied | 64 | signals | edit | 100 | 0.235 [0.230–0.235] |
| form | varied | 1 | vanilla | edit | 100 | 0.165 [0.165–0.175] |
| form | varied | 64 | vanilla | edit | 100 | 0.190 [0.185–0.200] |
| route | varied | 1 | expanded | leave | 100 | 0.265 [0.265–0.265] |
| route | varied | 64 | expanded | leave | 100 | 0.225 [0.220–0.225] |
| route | varied | 1 | indexed | leave | 100 | 0.290 [0.285–0.290] |
| route | varied | 64 | indexed | leave | 100 | 0.265 [0.260–0.265] |
| route | varied | 1 | lexical | leave | 100 | 0.265 [0.260–0.270] |
| route | varied | 64 | lexical | leave | 100 | 0.225 [0.220–0.230] |
| route | varied | 1 | scan | leave | 100 | 0.250 [0.245–0.250] |
| route | varied | 64 | scan | leave | 100 | 0.960 [0.940–0.990] |
| route | varied | 1 | signals | leave | 100 | 0.365 [0.355–0.380] |
| route | varied | 64 | signals | leave | 100 | 0.290 [0.290–0.295] |
| route | varied | 1 | vanilla | leave | 100 | 0.255 [0.250–0.260] |
| route | varied | 64 | vanilla | leave | 100 | 0.220 [0.215–0.225] |

## Owned-array edits

| Rows | Mode | Brotli | Edit | Swap | Select | Append/remove |
|---:|---|---:|---:|---:|---:|---:|
| 100 | reconcile | 525 | 0.600 [0.595–0.605] | 2.400 [2.375–2.480] | 0.470 [0.465–0.485] | 1.105 [1.100–1.155] |
| 100 | delta | 470 | 0.100 [0.095–0.100] | 0.120 [0.115–0.120] | 0.035 [0.035–0.040] | 0.205 [0.205–0.205] |
| 1000 | reconcile | 534 | 4.440 [4.275–4.635] | 21.995 [21.815–22.630] | 3.845 [3.825–3.955] | 7.750 [7.685–7.930] |
| 1000 | delta | 474 | 0.390 [0.380–0.410] | 0.430 [0.420–0.445] | 0.035 [0.035–0.035] | 0.175 [0.170–0.175] |
| 10000 | reconcile | 534 | 49.385 [49.345–50.400] | 234.105 [231.605–235.465] | 41.580 [41.380–41.805] | 82.580 [81.920–83.515] |
| 10000 | delta | 474 | 3.605 [3.505–3.715] | 3.710 [3.530–3.945] | 0.040 [0.040–0.040] | 0.230 [0.225–0.235] |

## Table, real clicks and traces

| Operation | Subject | Script ms | Total ms |
|---|---|---:|---:|
| 01_run1k | vanillajs | 6.891 [6.593–7.137] | 96.698 [41.625–102.502] |
| 01_run1k | candidate | 7.128 [6.898–7.447] | 98.995 [42.776–101.084] |
| 01_run1k | solid2 | 6.051 [5.777–6.201] | 92.589 [41.525–101.257] |
| 03_update10th1k_x16 | vanillajs | 0.404 [0.363–0.424] | 15.087 [8.105–16.215] |
| 03_update10th1k_x16 | candidate | 0.403 [0.372–0.449] | 15.288 [13.501–18.569] |
| 03_update10th1k_x16 | solid2 | 0.947 [0.901–0.977] | 15.517 [11.122–18.194] |
| 05_swap1k | vanillajs | 0.221 [0.217–0.234] | 16.337 [7.542–17.432] |
| 05_swap1k | candidate | 0.205 [0.188–0.222] | 10.610 [7.711–15.230] |
| 05_swap1k | solid2 | 0.712 [0.644–0.720] | 13.047 [12.700–14.043] |
| 06_remove-one-1k | vanillajs | 0.363 [0.347–0.404] | 25.255 [17.751–27.334] |
| 06_remove-one-1k | candidate | 0.152 [0.151–0.157] | 17.743 [13.845–27.269] |
| 06_remove-one-1k | solid2 | 0.468 [0.438–0.572] | 26.116 [25.743–27.349] |

## Static-heavy page

Median of each fresh page’s ten batch samples, then quartiles across nine pages. 100 events/batch.

| Subject | Script ms/batch | Forced layout after each event, ms/batch | Mount ms |
|---|---:|---:|---:|
| vanilla | 0.127 [0.125–0.132] | 1.795 [1.762–1.832] | 1.460 [1.450–1.490] |
| lexical | 0.123 [0.117–0.123] | 1.790 [1.765–1.838] | 1.560 [1.530–1.770] |
| solid2 | 0.325 [0.322–0.347] | 2.115 [2.098–2.163] | 3.315 [3.185–3.465] |
