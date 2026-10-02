<script>
    import { createEventDispatcher } from 'svelte';

    export let item;

    const dispatch = createEventDispatcher();

    function removeItem() {
        dispatch('removeItem');
    }
</script>

<li class:completed={item.completed}>
    <div class="view">
        <input class="toggle" type="checkbox" on:change={(event) => item.completed = event.target.checked} checked={item.completed} />
        <!-- svelte-ignore a11y-label-has-associated-control -->
        <label>{item.description}</label>
        <button on:click={removeItem} class="destroy" />
    </div>
</li>
