# Classifying one resource action (method v2)

You classify single Microsoft Entra resource actions (for example
`microsoft.directory/users/password/update`), not roles. For each action you give a plane, a
levelFloor and the service it belongs to.

This method combines two lines of reasoning:
- **Thomas Naunheim's EntraOps**: every action belongs to a *service* (a group of actions that
  serve one purpose, such as "Conditional Access" or "Microsoft 365 Support Operations"), and the
  service decides the tier. The services and their actions are in `ENTRAOPS-SERVICES.md`.
- **The maintainer's rules**, which always apply on top of the service.

The planes are Microsoft's Enterprise Access Model read as a control hierarchy: "prevent control of
higher planes from lower planes". EntraOps tiers map to planes: ControlPlane = **Control**,
ManagementPlane = **Management**, UserAccess = **Data**.

## Step 1: find the service

Find the EntraOps service the action belongs to. Look, in this order, for:
1. the same entity with other property sets or verbs (for example `.../users/mobile/update` next to
   `.../users/basic/update`): an action on the same entity, for the same purpose, belongs to the same
   service;
2. the same resource type or feature under another entity name (for example a new kind of identity
   object next to "Agent Identity" or "Application and Workload Identity");
3. the purpose in Microsoft's description, compared with what the services contain.

If one service fits, the action takes that service's tier. Name the service. If no service fits,
write `"service": "new"` and reason from the planes directly (step 2 still applies); the maintainer
always reviews a new service.

How EntraOps draws its lines, which you follow when you reason about fit:
- Control holds everything that steers identity, authentication, authorization and access across the
  tenant, and the platforms that can take over identities or devices: users, security groups,
  applications and workload identities, agent identities, authentication, Conditional Access,
  cross-tenant and multi-tenant settings, entitlement and privileged access, hybrid sync, global
  endpoint management, backup and recovery of the directory, licence management, tenant management
  and tenant policy. Within those services, reads of the service's own objects can be Control too.
- Management holds workload and platform administration bounded to a service (Exchange, SharePoint,
  Teams, Microsoft 365 groups, Microsoft 365 backup, platform operations, billing), security and
  compliance tooling, support and service health, and reading tenant configuration
  ("Tenant Configuration (Reader)").
- Data (UserAccess) holds what a normal member or guest can do for themselves.

## Step 2: the maintainer's rules (always, on top of the service)

1. An action Microsoft flags `isPrivileged: true` is **Control**, whatever the service says.
2. A read that reveals a secret that grants access (a key, a recovery key, a password, a token) is
   **Control**.
3. Conditions (`$SubjectIsOwner`, `$ResourceIsSelf`) are handled at role level. Classify the action
   itself, without the condition. How many roles hold it with or without a condition is context only.
4. Permissions a role has that are not listed as actions are handled at role level, not here.

## Step 3: levelFloor, the minimum protection level

Levels are Microsoft's privileged access security levels: Enterprise, Specialized, Privileged.

- **Privileged**: Microsoft flags the action `isPrivileged: true` (a flagged read is still
  Privileged); or the action gives full access to the content of a whole content workload (all mail,
  all files and sites, all chat, all source code, all business-application data), typically
  `<workload>/allEntities/allTasks` of such a workload.
- **Specialized**: the action writes (create, update, delete, allTasks, manage, enable, disable,
  restore, ...) something that shapes identity or access, or administers a service, and is not
  Privileged.
- **Enterprise**: everything else: reads that Microsoft does not flag, support and service health,
  end-user and self-service actions.

## Reading an action name

`<namespace>/<entity>/<propertySet>/<action>`. `allProperties` includes privileged properties,
`standard` excludes privileged properties for read, `basic` excludes privileged properties for
update, `allTasks` means create, read, update and delete, `allEntities` means every entity of the
namespace. Use Microsoft's description of the action and the action name together.

## Confidence

- **high**: the service fit (or the rule that applies) is clear.
- **medium**: the method decides it, but placing it in a service took judgement.
- **low**: no service fits well, or you cannot tell what the action does.
