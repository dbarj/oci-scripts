# oci-scripts

Some time saver scripts that will make Oracle Cloud Infrastructure management easier. Feel free to fork or suggest improvements.

For some description and usage instructions, please check [dbarj](https://www.dbarj.com.br/).

### oci_json_export.sh

Tool to export all your OCI metadata into JSON files.

[https://www.dbarj.com.br/en/2018/10/howto-backup-oracle-cloud-infrastructure-metadata/](https://www.dbarj.com.br/en/2018/10/howto-backup-oracle-cloud-infrastructure-metadata/).

### oci_compute_instance_reshape.sh

This script will automate all necessary tasks to change a compute instance shape.

[https://www.dbarj.com.br/en/2018/08/oracle-oci-reshape-compute-instance-script/](https://www.dbarj.com.br/en/2018/08/oracle-oci-reshape-compute-instance-script/).

### oci_fill_subnet_ips.sh

This script will use all availables IPs in your subnet creating dummy instances to allocate them. You can also define an exception list. The target here is to force a private IP in a Load Balancer.

[https://www.dbarj.com.br/en/2019/04/force-a-private-ip-during-load-balancer-creation-in-oci/](https://www.dbarj.com.br/en/2019/04/force-a-private-ip-during-load-balancer-creation-in-oci/).

### oci_network_seclist_clone_rules.sh

This script will clone all the security list rules from one SecList into another. Those SecLists can also be on different regions or compartments. You may also define sed replace regexp to modify some of the rules while cloning.

[https://www.dbarj.com.br/en/2019/04/cloning-security-list-rules-among-different-sls-in-oci/](https://www.dbarj.com.br/en/2019/04/cloning-security-list-rules-among-different-sls-in-oci/).

### oci_compute_clone.sh

This script will clone compute within a Region, to any Compartments or VCN. It will also clone all compute attributes and disks associated.

### oci_compute_clone_xregion.sh

This script will clone compute from one Region to another, in any Compartments or VCN. It will also clone all compute attributes and disks associated.

### oci_compute_fix_bv.sh

This program will automate all steps that you may execute to recover the a non-booting machine. It will attach the boot volume from one instance into another and mount it.

