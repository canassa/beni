<script>
    let { item, onRemoveItem } = $props();
</script>

<li class:completed={item.completed}>
    <div class="view">
        <input class="toggle" type="checkbox" onchange={(event) => item.completed = event.target.checked} checked={item.completed} />
        <!-- svelte-ignore a11y_label_has_associated_control -->
        <label>{item.description}</label>
        <button onclick={onRemoveItem} class="destroy" aria-label="Delete"></button>
    </div>
</li>
