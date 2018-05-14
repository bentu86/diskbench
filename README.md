# diskbench

## Install
```
cd rpms
yum install *.rpm
```

## Parameters
```
Usage: diskbench.sh: [OPTIONS]
  -d devices      : Device list(sep with space) or file contains device,one device per line
  -s size         : Test file size (default: 4G)
  -i iodepth      : I/O depth (used by fio) (default: 1)
  -b bs           : Block size (used by fio) (default: 8K)
  -m rw           : rw model (used by fio) (default : read)
  -x rwmixread    : rwmixread (used by fio) (default : 50)
  -t runtime      : Set the runtime for indiviual FIO test (default: 120 seconds)
  -c              : timebase,ignore size param
  -p profile      : use profile contais fio params
  -l              : long output format
  -a data dir     : analyze data dir only
  -n interval     : interval of dc (default : 5 seconds)
  -q              : quietly,hide log messages
  -z              : init write disk
```

## Examples

### test one disk with spedified model
```
sh diskbench.sh -d /dev/xvde -b 4k -m randwrite -i 1 -s 10G -t 120 -c
```

### test one disk with profile(multiple model)
```
sh diskbench.sh -d /dev/xvde -p examples/s3.txt
```

### test multiple disk with profile
```
lsblk -pd | grep 100G | awk '{print $1}' > disks.txt
sh diskbench.sh -d disks.txt -p examples/s3_vm.txt
```

## Results
fio_result\result.csv: test result of every single disk and model
fio_result\summary.csv: test result of every single model

## FAQ
