please read the stig rule and fix these ansible blocks, thanks

# defaults/main.yml

# R-230552 RHEL-08-040310
rhel8STIG_stigrule_230552_Manage: True
rhel8STIG_stigrule_230552_aide_package_state: 'present'
rhel8STIG_stigrule_230552_aide_acl_rule: 'acl' # Value is 'acl' as the '+' will be added in the replace task


---

tasks/main.yml

# R-230552 RHEL-08-040310
- name: stigrule_230552_ensure_aide_installed
  ansible.builtin.yum:
    name: aide
    state: "{{ rhel8STIG_stigrule_230552_aide_package_state }}"
  when: rhel8STIG_stigrule_230552_Manage

- name: stigrule_230552_configure_aide_acls
  ansible.builtin.replace:
    path: /etc/aide.conf
    regexp: '^(?!#)(.+?)(?:\\+{{ rhel8STIG_stigrule_230552_aide_acl_rule }})?(\s*#.*)?$'
    replace: '\1+{{ rhel8STIG_stigrule_230552_aide_acl_rule }}\2'
    backup: yes 
  when:
    - rhel8STIG_stigrule_230552_Manage
    # Only run if aide.conf exists (it should after aide package install)
    - ansible.builtin.stat(path='/etc/aide.conf').stat.exists

- name: stigrule_230552_initialize_aide_database
  ansible.builtin.command: aide --init
  args:
    creates: /var/lib/aide/aide.db.new.gz # Only run if the new DB doesn't exist
  when:
    - rhel8STIG_stigrule_230552_Manage
    - ansible.builtin.stat(path='/etc/aide.conf').stat.exists # Ensure aide.conf is there
  register: aide_init_result_acl
  changed_when: "'writing' in aide_init_result_acl.stderr or 'writing' in aide_init_result_acl.stdout"

- name: stigrule_230552_rename_aide_database
  ansible.builtin.command: "mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz"
  when:
    - rhel8STIG_stigrule_230552_Manage
    - aide_init_result_acl.changed # Only rename if init actually created a new DB

---

