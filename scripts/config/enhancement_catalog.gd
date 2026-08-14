class_name EnhancementCatalog
extends Resource

@export var entries: Array[EnhancementEntry] = []

func available(stacks: Dictionary) -> Array[EnhancementEntry]:
	var result: Array[EnhancementEntry] = []
	for entry in entries:
		if int(stacks.get(entry.id, 0)) < entry.max_stack:
			result.append(entry)
	return result

