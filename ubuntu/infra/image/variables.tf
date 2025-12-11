variable "img" {
  type = map(any)
  default = {
    img1 = {
      name            = "ubuntu2404"
      local_file_path = "/home/ubuntu/cloud/debootstrap/ubuntu2404/ubuntu2404.qcow2"
    }
    #img2 = {
    #  name            = "ubuntu1804"
    #  local_file_path = "/iso/c3/ubuntu1804.qcow2"
    #}
    #img3 = {
    #  name            = "debian10"
    #  local_file_path = "/iso/c3/debian10.qcow2"
    #}
    #img4 = {
    #  name            = "centos8"
    #  local_file_path = "/iso/c3/centos8.qcow2"
    #}
    #img6 = {
    #  name            = "centos9"
    #  local_file_path = "/iso/c3/centos9.qcow2"
    #}
    #img7 = {
    #  name            = "ubuntu24.04"
    #  local_file_path = "/iso/c3/noble-server-cloudimg-amd64.img"
    #}
  }
}

