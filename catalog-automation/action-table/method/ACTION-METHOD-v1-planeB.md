# Classifying one resource action

You classify single Microsoft Entra resource actions (for example
`microsoft.directory/users/password/update`), not roles. For each action you give two values.

## 1. plane: what does holding this action give control over?

The planes are Microsoft's Enterprise Access Model read as a control hierarchy: "Tier 0 expands to
become the control plane", and the rule is to "prevent control of higher planes from lower planes".
Ask: if an attacker holds only this action, what can they take control of?

- **Control**: the action steers who can access what across the tenant, or hands over the means to do
  so. Examples: changing passwords, authentication methods, credentials or tokens of other identities;
  assigning roles or changing role definitions; changing authentication, authorization, Conditional
  Access or cross-tenant access policy; adding credentials to or granting permissions for applications
  and service principals; federation and domains; directory synchronization; privileged access and
  entitlement management; reading secrets that grant access (BitLocker recovery keys, local admin
  passwords). An action Microsoft flags `isPrivileged: true` is always Control: Microsoft defines a
  privileged permission as one that can "delegate management of directory resources to other users,
  modify credentials, authentication or authorization policies, or access restricted data".
- **Management**: enterprise-wide IT management of workloads, platforms and devices, bounded to that
  service. Examples: configuring Exchange, SharePoint, Teams or Intune; managing devices; licences;
  backup and restore of workloads; tenant-wide service settings that do not decide who can access what.
- **Data**: work inside one workload or on business data, telemetry, support and the user's own things.
  Examples: reading reports, usage data and the message center; support tickets and service health;
  reading workload content or configuration; end-user and self-service actions.

Reads: reading gives no control. A read is Control only when what it reads grants access (a secret,
a key, a password) or Microsoft flags it `isPrivileged: true`. A plain read of identity or security
configuration (users, groups, policies, settings) is not Control: it is Management when it reads
enterprise-wide IT configuration, Data otherwise.

## 2. levelFloor: the minimum protection level this action needs

Levels are Microsoft's privileged access security levels: Enterprise, Specialized, Privileged.

- **Privileged**: Microsoft flags the action `isPrivileged: true`; or the action gives full access to
  the content of a whole content workload (all mail, all files and sites, all chat, all source code,
  all business-application data), typically `<workload>/allEntities/allTasks` of such a workload.
- **Specialized**: the action writes (create, update, delete, allTasks, manage, enable, disable,
  restore, ...) something that shapes identity or access, or administers a service, and is not
  Privileged.
- **Enterprise**: everything else: reads that Microsoft does not flag, support and service health,
  end-user and self-service actions.

A read that Microsoft flags `isPrivileged: true` is Privileged: being a read does not lower it.

## Reading an action name

`<namespace>/<entity>/<propertySet>/<action>`. `allProperties` includes privileged properties,
`standard` excludes privileged properties for read, `basic` excludes privileged properties for
update, `allTasks` means create, read, update and delete, `allEntities` means every entity of the
namespace. Use Microsoft's description of the action, and the action name, together.

## Conditions

Some roles hold an action only on their own objects (`$SubjectIsOwner`) or on themselves
(`$ResourceIsSelf`). Classify the action as such, without the condition: the condition is handled at
role level. You will see how many roles hold it with and without a condition; that is context only.

## Confidence

- **high**: the name and Microsoft's description leave no doubt.
- **medium**: the method decides it, but it took judgement.
- **low**: you cannot tell what the action does, or you chose the stricter value out of doubt.
