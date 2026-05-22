#!/bin/bash

set -x 

ll_id="com.visualstudio.code"

# Options
## Auto cleaning, default blank value means "true/TRUE"
auto_clean=""
## Auto push to specified repo, if success. Default blank value means "false/FALSE"
auto_push=""

repo_name="nightly"
repo_url="https://repo-dev.cicd.getdeepin.org"
push_account_user=""
push_account_passwd=""

init_global_data() {
  ARCH=$(uname -m)

  origin_version=""
  ll_version=""
  binary_arch=""
  linyaps_arch=""
  src_path=""
  output_dir=""

  project_root="$(dirname "$(readlink -f "$0")")"
  build_tmp_dir=$(mktemp -d)
  default_output_dir="${project_root}/bins"

  COMMANDLINE="$@"
  for COMMAND in $COMMANDLINE
  do
      key=$(echo $COMMAND | awk -F"=" '{print $1}')
      val=$(echo $COMMAND | awk -F"=" '{print $2}')

      case $key in
          --linyaps_arch)
              linyaps_arch="$val"
          ;;
          --origin_version)
              origin_version="$val"
          ;;
          --ll_version)
              ll_version="$val"
          ;;
          --src_path)
              src_path="$val"
          ;;          
          --output_dir)
              output_dir="$val"
          ;;              
      esac
  done
  
  case "${linyaps_arch}" in
    "x86_64")
      binary_arch="amd64"
      src_name="code_${origin_version}_${binary_arch}.deb"
      base_id="org.deepin.base"
      base_version="25.2.2"
      runtime_id="org.deepin.runtime.dtk"
      runtime_version="25.2.2"
      ;;
    "arm64")
      binary_arch="arm64"
      src_name="code_${origin_version}_${binary_arch}.deb"
      base_id="org.deepin.base"
      base_version="25.2.0"
      runtime_id="org.deepin.runtime.dtk"
      runtime_version="25.2.0"      
      ;;
    *)
      echo "Unsupported architecture: ${linyaps_arch}"
      exit 1
      ;;
  esac  
}

validate_version_format() {
    local version="$1"
    if [[ -n "${version}" \
    && "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 0
    else
        return 1
    fi
}

generate_version_from_origin() {
    local origin_ver="$1"
    
    if [[ -z "${origin_ver}" ]]; then
        echo "错误: origin_version 为空" >&2
        return 1
    fi
    
    local cleaned_version="${origin_ver%%~*}"
    
    local version_parts=()
    local temp_version="${cleaned_version}"
    
    while [[ "${temp_version}" =~ ([0-9]+)(.*) ]]; do
        version_parts+=("${BASH_REMATCH[1]}")
        temp_version="${BASH_REMATCH[2]#*[!0-9]}"
    done
    
    if [[ ${#version_parts[@]} -lt 2 ]]; then
        echo "错误: origin_version 格式不正确，无法提取足够的数字部分" >&2
        return 1
    fi
    
    local major="${version_parts[0]:-0}"
    local minor="${version_parts[1]:-0}"
    local patch="${version_parts[2]:-0}"
    local build="${version_parts[3]:-0}"
    
    local generated_version="${major}.${minor}.${patch}.${build}"
    
    if validate_version_format "${generated_version}"; then
        echo "${generated_version}"
        return 0
    else
        echo "错误: 生成的版本号格式不正确: ${generated_version}" >&2
        return 1
    fi
}

version_check_regroup() {
    if validate_version_format "${ll_version}"; then
        echo "Using existing valid ll_version=${ll_version}"
    else
        echo "ll_version 格式不正确或为空，尝试使用 origin_version 生成"
        
        local generated_version
        if generated_version=$(generate_version_from_origin "${origin_version}"); then
            ll_version="${generated_version}"
            echo "Using origin_version=${origin_version} to generate ll_version=${ll_version}"
        else
            echo "无法从 origin_version 生成有效的版本号"
            exit 1
        fi
    fi
    
    echo "Final ll_version=${ll_version}"
}

validate_required_fields() {
  if [ -z "${src_path}" ]; then
    if [ -f "${default_src_path}" ]; then
      echo "Using default src_path=${default_src_path}"
      src_path="${default_src_path}"
    else
      echo "请指定有效的源包完整路径 src_path" >&2
      exit 1
    fi
  elif [ ! -f "${src_path}" ]; then
    echo "指定的源包文件不存在: ${src_path}" >&2
    exit 1
  fi

  if [ ! -d "${output_dir}" ]; then
    echo "请指定输出目录 output_dir" >&2
    exit 1
  fi

  if [ -z "${ll_version}" ]; then
    echo "请单独指定 ll_version 或 提供正确的 origin_version" >&2
    exit 1
  fi

  if [ -z "${linyaps_arch}" ]; then
    linyaps_arch=$(uname -m)
  fi
}

data_regroup_check() {
  src_path=$(readlink -f "${src_path}")
  output_dir=$(readlink -f "${output_dir}")
  default_src_path="${project_root}/src/${src_name}"

  version_check_regroup
  validate_required_fields
}

build_dir_init() {
  ## Generate linyaps building dir
  mkdir -p "${build_tmp_dir}/binary"
  cd "${build_tmp_dir}"
  cp -rf "${project_root}/templates/files_res" \
  "${build_tmp_dir}"

  ## Generate linyaps res
  ## Envs for linglong.yaml
  export prefix="\$PREFIX"
  export ll_version=${ll_version}
  export base_id=${base_id}
  export base_version=${base_version}
  export runtime_id=${runtime_id}
  export runtime_version=${runtime_version}
  export linyaps_arch=${linyaps_arch}

  cat "${project_root}/templates/linglong.yaml"\
| envsubst >"${build_tmp_dir}/linglong.yaml"
}

build_pak() {
  ## Extract the binary package
  binary_tmp_dir="${build_tmp_dir}/tmp"
  binary_dir="${build_tmp_dir}/binary/"

  dpkg -x "${src_path}" \
"${binary_tmp_dir}/"
  rsync -avrP "${binary_tmp_dir}/usr/share/code"\
 "${binary_dir}/"

  ## Building & Exporting
  ll-builder build --skip-output-check
  building_status=$?
  if [ "${building_status}" = "0" ]; then
    echo "Building success ! "
  else
    echo "Building failed ! "
    exit 1
  fi
  ll-builder export --no-develop --layer

  ## Check layers
  binary_layer=$(find "${build_tmp_dir}" -type f \
  -name "*binary.layer")
  if [ -z ${binary_layer} ]; then
    echo "Failed to build paks !"
    exit 1
  else
    mv "${binary_layer}" "${output_dir}"
  fi
}

push_dev() {
  ## Check data
  export LINGLONG_USERNAME="${LINGLONG_USERNAME:-$push_account_user}"
  export LINGLONG_PASSWORD="${LINGLONG_PASSWORD:-$push_account_passwd}"
  for data in repo_name repo_url LINGLONG_USERNAME LINGLONG_PASSWORD; do
    if [ -z "${!data}" ]; then
      echo "Error: Required '$data' is missing"
      exit 1
    fi
  done
  ## Push
  cd "${build_tmp_dir}"
  ll-builder push --repo-name ${repo_name} --repo-url ${repo_url}
}

main() {
    init_global_data "$@"
    data_regroup_check
    build_dir_init
    build_pak

      ## Auto push
      if [[ -n "${auto_push}" && ("${auto_push}" =~ ^[Tt][Rr][Uu][Ee]$ \
          || "${auto_push}" =~ ^[Tt]$) ]]; then
        push_dev
      else
        echo "Skip auto push due to empty or false value of auto_push"
      fi


    #Clean up the environment
    rm -fr ${base_name}

    ## Clean up
    if [ -z "${auto_clean}" ]\
      || [ "${auto_clean}" = "TRUE" ]\
      || [ "${auto_clean}" = "true" ] ; then
      rm -rf "${build_tmp_dir}"
    fi
}

main "$@"
exit 0